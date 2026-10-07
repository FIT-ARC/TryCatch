import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/services/live_bridge/bridge_schema.dart';
import 'package:trycatch/services/live_bridge/bridge_server.dart';

/// Harness driving a real bridge isolate over its message protocol.
///
/// Pings every 2 s like the relay, so the lease never expires mid-suite —
/// except in the lease test, which stops the pinger on purpose.
class _Bridge {
  final Isolate isolate;
  final SendPort command;
  final ReceivePort _fromBridge;
  final StreamController<Map> _statusController;
  Stream<Map> get statuses => _statusController.stream;
  Timer? _pinger;

  _Bridge(this.isolate, this.command, this._fromBridge, this._statusController);

  static Future<_Bridge> spawn() async {
    final fromBridge = ReceivePort();
    final isolate = await Isolate.spawn(
      liveBridgeMain,
      fromBridge.sendPort,
      debugName: 'LiveBridgeTest',
    );
    final commandCompleter = Completer<SendPort>();
    final statusController = StreamController<Map>.broadcast();
    fromBridge.listen((message) {
      if (message is! Map) return;
      if (message[LiveBridgeMessages.type] == LiveBridgeMessages.ready) {
        final port = message['commandPort'];
        if (port is SendPort && !commandCompleter.isCompleted) {
          commandCompleter.complete(port);
        }
        return;
      }
      if (message[LiveBridgeMessages.type] == LiveBridgeMessages.status) {
        statusController.add(message);
      }
    });
    final command = await commandCompleter.future.timeout(
      const Duration(seconds: 5),
    );
    final bridge = _Bridge(isolate, command, fromBridge, statusController);
    bridge._pinger = Timer.periodic(const Duration(seconds: 2), (_) {
      try {
        command.send({LiveBridgeMessages.type: LiveBridgeMessages.ping});
      } catch (_) {}
    });
    return bridge;
  }

  /// Stops the lease heartbeat: the bridge must free its socket and exit
  /// on its own past [bridgeLeaseMs].
  void stopPing() {
    _pinger?.cancel();
    _pinger = null;
  }

  Future<Map> waitForStatus(bool Function(Map) matches) {
    return statuses.firstWhere(matches).timeout(const Duration(seconds: 5));
  }

  Future<int> enable() async {
    command.send({
      LiveBridgeMessages.type: LiveBridgeMessages.config,
      'enabled': true,
      'port': 0,
      'bind': '127.0.0.1',
      'cors': '*',
    });
    final status = await waitForStatus(
      (s) => s['running'] == true && (s['port'] as int) != 0,
    );
    return status['port'] as int;
  }

  Future<String> getBody(String path, int port) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, HttpStatus.ok, reason: 'GET $path');
      return body;
    } finally {
      client.close();
    }
  }

  void dispose() {
    stopPing();
    _fromBridge.close();
    _statusController.close();
    isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

Map<String, dynamic> _envelope(int seq) => LiveBridgeSchema.packet(
  frame: TelemetryFrame(
    receivedAtMs: 1700000000000 + seq,
    latitude: 50.0 + seq * 0.001,
    longitude: 14.0,
    baroAltitude: 100.0 * seq,
    velocityNorth: 3.0 * seq,
    velocityEast: 4.0 * seq,
  ),
  siteMslM: 403,
  maxAltitudeAglM: 100.0 * seq,
  hasParachute: seq >= 2,
);

void main() {
  group('live bridge server', () {
    late _Bridge bridge;
    late int port;

    setUpAll(() async {
      bridge = await _Bridge.spawn();
      port = await bridge.enable();
    });

    tearDownAll(() {
      bridge.dispose();
    });

    test('serves a minimal health check and 204 before any packet', () async {
      final health = jsonDecode(await bridge.getBody('/health', port));
      expect(health, {'status': 'ok'});

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/latest'),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.noContent);
      } finally {
        client.close();
      }
    });

    test('publishes packets to latest and the event stream', () async {
      bridge.command.send({
        LiveBridgeMessages.type: LiveBridgeMessages.frame,
        'envelope': _envelope(1),
      });
      // Wait until the server picked the packet up.
      await bridge.waitForStatus((s) => s['hasFrame'] == true);

      final latest = jsonDecode(await bridge.getBody('/latest', port)) as Map;
      expect(latest.keys.toSet(), {
        'receivedAt',
        'gpsLat',
        'gpsLong',
        'altitudeMSL',
        'altitudeAGL',
        'hasParachute',
        'maxAltitude',
        'totalVelocity',
      });
      expect(latest['receivedAt'], 1700000000001);
      expect(latest['altitudeMSL'], closeTo(503.0, 1e-9));
      expect(latest['altitudeAGL'], 100.0);
      expect(latest['hasParachute'], false);

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/events'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers.contentType?.mimeType, 'text/event-stream');
        final events = <String>[];
        final sub = response
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.startsWith('data: ')) events.add(line.substring(6));
            });
        // The connect dump already carries packet 1; push packet 2 live.
        bridge.command.send({
          LiveBridgeMessages.type: LiveBridgeMessages.frame,
          'envelope': _envelope(2),
        });
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (events.length < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await sub.cancel();
        expect(events.length, greaterThanOrEqualTo(2));
        final last = jsonDecode(events.last) as Map;
        expect(last['receivedAt'], 1700000000002);
        expect(last['altitudeMSL'], closeTo(603.0, 1e-9));
        expect(last['altitudeAGL'], 200.0);
        expect(last['hasParachute'], true);
      } finally {
        client.close(force: true);
      }
    });

    test(
      'keeps the last packet when frames stop (age-based staleness)',
      () async {
        final first = jsonDecode(await bridge.getBody('/latest', port)) as Map;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final second = jsonDecode(await bridge.getBody('/latest', port)) as Map;
        expect(second['receivedAt'], first['receivedAt']);
      },
    );

    test(
      'idle SSE disconnects and reconnects track only open clients',
      () async {
        final idleBridge = await _Bridge.spawn();
        final idlePort = await idleBridge.enable();
        final clients = <HttpClient>[];
        final subscriptions = <StreamSubscription<String>>[];
        Future<void> connect(int count) async {
          final status = idleBridge.waitForStatus((s) => s['clients'] == count);
          final client = HttpClient();
          clients.add(client);
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$idlePort/events'),
          );
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);
          subscriptions.add(
            response
                .transform(utf8.decoder)
                .listen((_) {}, onError: (Object _) {}),
          );
          await status;
        }

        try {
          await connect(1);
          await connect(2);
          for (var i = 0; i < 3; i++) {
            final disconnected = idleBridge.waitForStatus(
              (s) => s['clients'] == 1,
            );
            clients.last.close(force: true);
            await disconnected;
            await connect(2);
          }
          final oneLeft = idleBridge.waitForStatus((s) => s['clients'] == 1);
          clients.first.close(force: true);
          await oneLeft;
          final noneLeft = idleBridge.waitForStatus((s) => s['clients'] == 0);
          clients.last.close(force: true);
          await noneLeft;
        } finally {
          for (final client in clients) {
            client.close(force: true);
          }
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          idleBridge.dispose();
        }
      },
    );

    test('orderly peer closure removes an idle SSE client', () async {
      final idleBridge = await _Bridge.spawn();
      final idlePort = await idleBridge.enable();
      final socket = await Socket.connect('127.0.0.1', idlePort);
      final closed = Completer<void>();
      final subscription = socket.listen((_) {}, onDone: closed.complete);
      try {
        final connected = idleBridge.waitForStatus((s) => s['clients'] == 1);
        socket.write('GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n');
        await socket.flush();
        await connected;
        final disconnected = idleBridge.waitForStatus((s) => s['clients'] == 0);
        await socket.close();
        await disconnected;
        await closed.future.timeout(const Duration(seconds: 5));
      } finally {
        socket.destroy();
        await subscription.cancel();
        idleBridge.dispose();
      }
    });

    test(
      'disabling sharing closes owned SSE sockets and clears the count',
      () async {
        final idleBridge = await _Bridge.spawn();
        final idlePort = await idleBridge.enable();
        final client = HttpClient();
        StreamSubscription<String>? subscription;
        try {
          final connected = idleBridge.waitForStatus((s) => s['clients'] == 1);
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$idlePort/events'),
          );
          final response = await request.close();
          final closed = Completer<void>();
          subscription = response
              .transform(utf8.decoder)
              .listen((_) {}, onDone: closed.complete);
          await connected;
          final stopped = idleBridge.waitForStatus(
            (s) => s['running'] == false && s['clients'] == 0,
          );
          idleBridge.command.send({
            LiveBridgeMessages.type: LiveBridgeMessages.config,
            'enabled': false,
          });
          await stopped;
          await closed.future.timeout(const Duration(seconds: 5));
        } finally {
          client.close(force: true);
          await subscription?.cancel();
          idleBridge.dispose();
        }
      },
    );

    test('is read-only and answers CORS preflights', () async {
      final client = HttpClient();
      try {
        final post = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/latest'),
        );
        final postResponse = await post.close();
        await postResponse.drain<void>();
        expect(postResponse.statusCode, HttpStatus.methodNotAllowed);

        final missing = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/nope'),
        );
        final missingResponse = await missing.close();
        await missingResponse.drain<void>();
        expect(missingResponse.statusCode, HttpStatus.notFound);

        final options = await client.openUrl(
          'OPTIONS',
          Uri.parse('http://127.0.0.1:$port/latest'),
        );
        final optionsResponse = await options.close();
        await optionsResponse.drain<void>();
        expect(optionsResponse.statusCode, HttpStatus.noContent);
        expect(
          optionsResponse.headers.value('access-control-allow-origin'),
          '*',
        );
      } finally {
        client.close();
      }
    });

    test(
      'duplicate back-to-back configs do not fail against each other',
      () async {
        // Startup delivers the same config twice (queued pre-handshake config
        // plus the fresh send on ready); the second must be a no-op report,
        // not a rebind that fails with a busy port.
        final seen = <Map>[];
        final sub = bridge.statuses.listen(seen.add);
        Map<String, dynamic> config() => {
          LiveBridgeMessages.type: LiveBridgeMessages.config,
          'enabled': true,
          'port': port,
          'bind': '127.0.0.1',
          'cors': '*',
        };
        bridge.command.send(config());
        bridge.command.send(config());
        await Future<void>.delayed(const Duration(seconds: 1));
        await sub.cancel();
        expect(seen.where((s) => s['error'] != null), isEmpty);
        expect(seen.where((s) => s['running'] == true), isNotEmpty);
        final health = jsonDecode(await bridge.getBody('/health', port));
        expect(health, {'status': 'ok'});
      },
    );

    test('stops serving when disabled', () async {
      bridge.command.send({
        LiveBridgeMessages.type: LiveBridgeMessages.config,
        'enabled': false,
        'port': 0,
        'bind': '127.0.0.1',
        'cors': '*',
      });
      await bridge.waitForStatus((s) => s['running'] != true);
      final client = HttpClient();
      try {
        expect(
          client.getUrl(Uri.parse('http://127.0.0.1:$port/health')),
          throwsA(isA<SocketException>()),
        );
      } finally {
        client.close();
      }
    });

    test(
      'unpinged bridge frees its socket and exits (hot-restart orphan)',
      () async {
        // Must run last: the isolate dies here.
        port = await bridge.enable();
        bridge.stopPing();
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (DateTime.now().isBefore(deadline)) {
          final client = HttpClient();
          try {
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:$port/health'),
            );
            final response = await request.close();
            await response.drain<void>();
          } on SocketException {
            return;
          } finally {
            client.close();
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        fail('bridge still holds its socket past the lease');
      },
    );
  });

  group('bridgeLeaseExpired', () {
    test('fires once past the lease, not before', () {
      expect(
        bridgeLeaseExpired(lastSignalMs: 1000, nowMs: 1000 + bridgeLeaseMs),
        false,
      );
      expect(
        bridgeLeaseExpired(lastSignalMs: 1000, nowMs: 1000 + bridgeLeaseMs + 1),
        true,
      );
      expect(
        bridgeLeaseExpired(lastSignalMs: 1000, nowMs: 2000, leaseMs: 5000),
        false,
      );
    });
  });

  group('bridgeClientExpired', () {
    test('fires once past the TTL, not before', () {
      expect(
        bridgeClientExpired(joinedMs: 1000, nowMs: 1000 + bridgeClientTtlMs),
        false,
      );
      expect(
        bridgeClientExpired(
          joinedMs: 1000,
          nowMs: 1000 + bridgeClientTtlMs + 1,
        ),
        true,
      );
      expect(
        bridgeClientExpired(joinedMs: 1000, nowMs: 2000, ttlMs: 5000),
        false,
      );
    });
  });
}
