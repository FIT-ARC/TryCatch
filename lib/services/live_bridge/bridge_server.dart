import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Read-only live telemetry HTTP server running in its own isolate.
///
/// The main isolate forwards already-built packet maps (see
/// `LiveBridgeSchema`); this isolate never touches serial ports, the
/// flight store, or Flutter plugins — it only binds a socket and fans the
/// latest JSON string out to HTTP clients. A crash here ends the isolate,
/// never the app.
///
/// Message protocol (main → bridge, plain maps only):
/// - `{type: 'config', enabled, port, bind, cors}`: (re)bind or stop.
/// - `{type: 'frame', envelope}`: new live packet; becomes `/latest` and is
///   broadcast to every SSE client. The envelope is the whole body.
///
/// Bridge → main: `{type: 'status', running, port, bind, clients, hasFrame,
/// error}` on start/stop/failure/client-count/first-frame transitions, plus
/// the handshake `{type: 'ready', commandPort}` first.
///
/// Routes (GET only; everything else is 405, so there is no inbound path):
/// - `GET /latest`: newest packet as JSON, or 204 before the first packet.
/// - `GET /events`: server-sent events stream of packets.
/// - `GET /health`: `{status: 'ok'}` (minimal proxy/load-balancer check).
void liveBridgeMain(SendPort mainSendPort) {
  final inbox = ReceivePort();
  mainSendPort.send({'type': 'ready', 'commandPort': inbox.sendPort});
  final host = _BridgeHost(
    sendStatus: (status) {
      mainSendPort.send(status);
    },
    onLeaseExpired: () {
      try {
        inbox.close();
      } catch (_) {}
    },
  );
  inbox.listen((message) {
    if (message is! Map) return;
    host.handle(message);
  });
}

/// Message keys shared with the relay (kept here so tests use one source).
abstract final class LiveBridgeMessages {
  static const String type = 'type';
  static const String config = 'config';
  static const String frame = 'frame';
  static const String ping = 'ping';
  static const String status = 'status';
  static const String ready = 'ready';
}

/// How long an SSE flush may take before its client is treated as dead.
///
/// A flush that never settles means a wedged socket, and wedged sockets
/// otherwise linger as phantom clients: `response.done` does not reliably
/// fire for never-ending SSE streams, and bare write failures do not
/// surface on every stack — without this bound, a dead client is only
/// reaped when a flush observably errors, which may be never.
const Duration _clientFlushTimeout = Duration(seconds: 10);

/// Maximum SSE subscription age, in milliseconds.
///
/// Dead sockets are not reliably reported by the platform: `response.done`
/// may never fire for a never-ending SSE stream, and writes to a dead
/// socket may neither error nor settle — without a TTL every reconnect
/// leaks a phantom client and the count only ever grows. The heartbeat
/// sweep reaps connections past this age; live clients transparently
/// reconnect (`retry: 2000`, latest-only model, so no visible gap).
const int bridgeClientTtlMs = 10 * 60 * 1000;

/// Pure expiry check (unit-tested): `true` once [nowMs] is more than [ttlMs]
/// past the client's join time.
bool bridgeClientExpired({
  required int joinedMs,
  required int nowMs,
  int ttlMs = bridgeClientTtlMs,
}) =>
    nowMs - joinedMs > ttlMs;

/// Liveness lease for the bridge isolate, in milliseconds.
///
/// Child isolates survive a hot restart holding the server socket, so a
/// bridge whose main isolate is gone must free the port and exit instead of
/// squatting on it forever (same pattern as the serial worker lease).
/// Every received message (config, frame, ping) renews the lease; the relay
/// pings every 2 s and retries the bind while enabled, so a restart
/// recovers automatically within a few seconds.
const int bridgeLeaseMs = 8000;

/// Pure lease check (unit-tested): `true` once [nowMs] is more than
/// [leaseMs] past the last message from the main isolate.
bool bridgeLeaseExpired({
  required int lastSignalMs,
  required int nowMs,
  int leaseMs = bridgeLeaseMs,
}) =>
    nowMs - lastSignalMs > leaseMs;

class _BridgeHost {
  final void Function(Map<String, dynamic> status) sendStatus;

  /// Runs when the lease expires (after the server is closed): releases the
  /// isolate's last port so the isolate exits.
  final void Function() onLeaseExpired;

  _BridgeHost({required this.sendStatus, required this.onLeaseExpired}) {
    _leaseTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_server != null &&
          bridgeLeaseExpired(
            lastSignalMs: _lastSignalMs,
            nowMs: DateTime.now().millisecondsSinceEpoch,
          )) {
        _expire();
      }
    });
  }

  HttpServer? _server;

  /// Live SSE subscriptions by join time (epoch ms). A map, not a set: the
  /// heartbeat sweep reaps connections past [bridgeClientTtlMs], bounding how
  /// long a phantom client can inflate the count.
  final Map<HttpResponse, int> _sseClients = {};
  Timer? _heartbeat;
  Timer? _leaseTimer;

  /// Last message (any type, pings included) from the main isolate. Past
  /// [bridgeLeaseMs] with a socket held, the main is gone and the isolate
  /// frees the port and exits instead of squatting on it.
  int _lastSignalMs = DateTime.now().millisecondsSinceEpoch;

  String _bind = '127.0.0.1';
  int _port = 6767;

  /// Requested port; the bound socket may differ when 0 was requested.
  int _boundPort = 6767;
  String _cors = '*';

  /// Pre-encoded latest packet; the fan-out hot path never encodes.
  String? _latestJson;
  bool _hasFrame = false;

  bool get _running => _server != null;

  void handle(Map message) {
    // Any message proves the main isolate is alive — renew the lease.
    _lastSignalMs = DateTime.now().millisecondsSinceEpoch;
    switch (message[LiveBridgeMessages.type]) {
      case LiveBridgeMessages.config:
        _applyConfig(message);
      case LiveBridgeMessages.frame:
        _publish(message['envelope']);
      case LiveBridgeMessages.ping:
        break;
    }
  }

  /// Lease expiry: free the socket, then release the isolate itself. The
  /// status below only ever reaches a live listener in tests; a dead main
  /// hears nothing.
  Future<void> _expire() async {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    await _stop();
    try {
      onLeaseExpired();
    } catch (_) {}
  }

  Future<void> _applyConfig(Map message) async {
    final enabled = message['enabled'] == true;
    final port = message['port'];
    final bind = message['bind'];
    final cors = message['cors'];
    if (port is int) _port = port;
    if (bind is String && bind.isNotEmpty) _bind = bind;
    if (cors is String && cors.isNotEmpty) _cors = cors;
    if (!enabled) {
      await _stop();
      return;
    }
    if (_running && _boundPort == _port && _server!.address.host == _bind) {
      _report();
      return;
    }
    await _stop();
    try {
      _server = await HttpServer.bind(_bind, _port);
      _boundPort = _server!.port;
    } catch (e) {
      _report(error: '$e');
      return;
    }
    _server!.listen(_onRequest);
    _heartbeat ??= Timer.periodic(const Duration(seconds: 15), (_) {
      _reapExpired();
      _broadcastComment('ping');
    });
    _report();
  }

  void _publish(dynamic envelope) {
    if (envelope is! Map) return;
    try {
      _latestJson = jsonEncode(envelope);
    } catch (_) {
      return;
    }
    final becameLive = !_hasFrame;
    _hasFrame = true;
    _broadcastData(_latestJson!);
    if (becameLive) _report();
  }

  Future<void> _stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    for (final client in _sseClients.keys.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _sseClients.clear();
    final wasRunning = _running;
    if (_server != null) {
      try {
        await _server!.close(force: true);
      } catch (_) {}
      _server = null;
    }
    if (wasRunning) _report();
  }

  void _report({String? error}) {
    sendStatus({
      LiveBridgeMessages.type: LiveBridgeMessages.status,
      'running': _running,
      'port': _boundPort,
      'bind': _bind,
      'clients': _sseClients.length,
      'hasFrame': _hasFrame,
      'error': error,
    });
  }

  Future<void> _onRequest(HttpRequest request) async {
    final response = request.response;
    _applyCors(response);
    try {
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'error': 'read-only bridge'}));
        await response.close();
        return;
      }
      switch (request.uri.path) {
        case '/health':
          _writeJson(response, {'status': 'ok'});
        case '/latest':
          final latest = _latestJson;
          if (latest == null) {
            response.statusCode = HttpStatus.noContent;
            await response.close();
          } else {
            response.headers.contentType = ContentType.json;
            response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
            response.write(latest);
            await response.close();
          }
        case '/events':
          await _serveEvents(request);
        default:
          response.statusCode = HttpStatus.notFound;
          _writeJson(response, {'error': 'not found'});
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  void _writeJson(HttpResponse response, Map<String, dynamic> body) {
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(jsonEncode(body));
    response.close();
  }

  Future<void> _serveEvents(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('Connection', 'keep-alive');
    response.bufferOutput = false;
    response.write('retry: 2000\n\n');
    if (_latestJson != null) response.write('data: $_latestJson\n\n');
    try {
      await response.flush();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
      return;
    }
    _sseClients[response] = DateTime.now().millisecondsSinceEpoch;
    _report();
    try {
      await response.done;
    } catch (_) {}
    _sseClients.remove(response);
    _report();
  }

  /// Reaps subscriptions past [bridgeClientTtlMs], pushing a status when the set
  /// shrinks. Runs on the heartbeat sweep: socket death is not reliably
  /// observable, so age is the backstop that bounds phantom clients.
  void _reapExpired() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var dropped = false;
    for (final entry in _sseClients.entries.toList()) {
      if (bridgeClientExpired(joinedMs: entry.value, nowMs: nowMs)) {
        try {
          entry.key.close();
        } catch (_) {}
        dropped = _sseClients.remove(entry.key) != null || dropped;
      }
    }
    if (dropped) _report();
  }

  void _broadcastData(String json) {
    for (final client in _sseClients.keys.toList()) {
      try {
        client.write('data: $json\n\n');
        _flushTo(client);
      } catch (_) {
        _dropClient(client);
      }
    }
  }

  void _broadcastComment(String comment) {
    for (final client in _sseClients.keys.toList()) {
      try {
        client.write(': $comment\n\n');
        _flushTo(client);
      } catch (_) {
        _dropClient(client);
      }
    }
  }

  /// Flushes pending SSE bytes to [client], dropping it (with a status)
  /// when the flush errors or stalls past [_clientFlushTimeout].
  void _flushTo(HttpResponse client) {
    () async {
      try {
        await client.flush().timeout(_clientFlushTimeout);
      } catch (_) {
        _dropClient(client);
      }
    }();
  }

  /// Drops [client] from the subscription map, pushing a status when the
  /// map shrinks so a reaped socket never leaves the count stale-high.
  void _dropClient(HttpResponse client) {
    if (_sseClients.remove(client) != null) _report();
  }

  void _applyCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', _cors);
    response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', '*');
  }
}
