import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/foundation/time/rate_series.dart';
import 'package:trycatch/session/flight_reset.dart';
import 'package:trycatch/services/recording_repository.dart';
import 'package:trycatch/state/channel_health_provider.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/telemetry_store.dart';

/// Full-stack app flows against the real serial worker isolate + MOCK port.
///
/// Unit tests pin each layer (codec, recorder, seek math, widgets). These
/// pin the wiring between them: connect → live ingest → record → stop →
/// file → replay → stop → live, plus uplink filing and buffer clearing.
/// Container-only (all subscriptions under test live in provider `build`,
/// so no widget harness is needed).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SerialWorker worker;
  Timer? ping;
  late Directory pathDir;

  setUpAll(() async {
    // No network or tile disk cache under test: fail HTTP fast so terrain
    // queries resolve to null immediately instead of hanging on timeouts.
    HttpOverrides.global = _OfflineHttpOverrides();
    // flutter_map's disk cache needs a cache dir: point path_provider at
    // temp (its constructor otherwise throws an unhandled async error).
    pathDir =
        await Directory.systemTemp.createTemp('trycatch_path_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => pathDir.path,
    );
    worker = await SerialWorker.spawn();
    await worker.ready;
    ping = Timer.periodic(
      const Duration(seconds: 2),
      (_) => worker.send(const PingCommand()),
    );
  });

  tearDownAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    // The tile cache may still hold its DB file open; best effort only.
    try {
      pathDir.deleteSync(recursive: true);
    } catch (_) {}
    ping?.cancel();
    worker.dispose();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [serialWorkerProvider.overrideWithValue(worker)],
    );
    // Bare-container `read` does not drive StreamProviders (same root cause
    // as the widget-harness NOTE in serial_connecting_test): keep explicit
    // subscriptions so status/frames/link-stats flow without widgets.
    container.listen(serialStatusProvider, (_, _) {});
    container.listen(telemetryStreamProvider, (_, _) {});
    container.listen(linkStatsStreamProvider, (_, _) {});
    container.listen(commandEventsProvider, (_, _) {});
    container.listen(serialErrorsProvider, (_, _) {});
    container.listen(availablePortsProvider, (_, _) {});    addTearDown(container.dispose);
    return container;
  }

  Future<void> waitFor(
    bool Function() done, {
    String reason = 'condition not met in time',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) throw TestFailure(reason);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> connectMock(ProviderContainer container) async {
    final config = container.read(serialConfigProvider.notifier);
    config.setPort('MOCK');
    config.connect();
    await waitFor(
      () => container.read(serialStatusProvider).value?.isConnected ?? false,
      reason: 'MOCK never reported connected',
    );
  }

  Future<void> disconnect(ProviderContainer container) async {
    container.read(serialConfigProvider.notifier).disconnect();
    await waitFor(
      () =>
          !(container.read(serialStatusProvider).value?.isConnected ?? true),
      reason: 'MOCK never reported disconnected',
    );
    // Let in-flight frames settle so post-disconnect asserts are stable.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  group('live link', () {
    test('MOCK connect streams telemetry into the store', () async {
      final container = newContainer();
      await connectMock(container);
      try {
        await waitFor(
          () => container.read(telemetryStoreProvider).packetCount > 0,
          reason: 'no live frames ingested',
        );
        final state = container.read(telemetryStoreProvider);
        expect(state.latest, isNotNull);
        expect(state.sourceName, 'MOCK');
        expect(state.history.isNotEmpty, isTrue);
      } finally {
        await disconnect(container);
      }
    });

    test('uplink while connected files a sent command', () async {
      final container = newContainer();
      await connectMock(container);
      try {
        final ok = container
            .read(serialConfigProvider.notifier)
            .sendBytes([0x54, 0x43, 0x05, 0x00],
                source: CommandSource.controlPanel);
        expect(ok, isTrue);
        await waitFor(
          () => container.read(commandLogProvider).isNotEmpty,
          reason: 'no command filed in the log',
        );
        final entry = container.read(commandLogProvider).last;
        expect(entry.status, CommandStatus.sent);
        expect(entry.source, CommandSource.controlPanel);
        expect(entry.bytes, [0x54, 0x43, 0x05, 0x00]);
      } finally {
        await disconnect(container);
      }
    });

    test('uplink while disconnected files a failed command', () async {
      final container = newContainer();
      final ok = container
          .read(serialConfigProvider.notifier)
          .sendBytes([0x54, 0x43, 0x05, 0x00],
              source: CommandSource.controlPanel);
      expect(ok, isFalse);
      final entry = container.read(commandLogProvider).last;
      expect(entry.status, CommandStatus.failed);
    });
  });

  group('record → file → replay', () {
    test('round trip preserves frames, site, connector and commands',
        () async {
      final container = newContainer();
      final tempDir =
          await Directory.systemTemp.createTemp('trycatch_flows_test_');
      try {
        await connectMock(container);
        final path =
            '${tempDir.path}${Platform.pathSeparator}e2e_flight.bin';

        worker.send(StartRecordingCommand(
          filePath: path,
          launch: const LaunchRef(
            latitude: 49.799,
            longitude: 16.693,
            mslM: 403,
            name: 'E2E Pad',
          ),
          connectorId: 'mock',
        ));
        await waitFor(
          () =>
              container.read(serialStatusProvider).value?.isRecording ?? false,
          reason: 'worker never reported recording',
        );

        // File one uplink mid-recording so the command section is covered.
        container.read(serialConfigProvider.notifier).sendBytes(
            [0x54, 0x43, 0x05, 0x00],
            source: CommandSource.controlPanel);
        await waitFor(
          () => container.read(commandLogProvider).isNotEmpty,
          reason: 'uplink not filed during recording',
        );
        await Future<void>.delayed(const Duration(seconds: 2));

        worker.send(const StopRecordingCommand());
        await waitFor(
          () =>
              !(container.read(serialStatusProvider).value?.isRecording ??
                  true),
          reason: 'worker never stopped recording',
        );
        await disconnect(container);

        // The file stands alone: header, site, connector, stats, commands.
        final header = await tryReadRecordingHeader(path);
        expect(header, isNotNull);
        expect(header!.connectorId, 'mock');
        expect(header.launchRef?.name, 'E2E Pad');
        expect(header.packetCount, greaterThan(0));

        final loaded = await RecordingRepository.loadReplay(path);
        expect(loaded, isNotNull);
        expect(loaded!.frames.isNotEmpty, isTrue);
        expect(
          loaded.commands.any((c) =>
              c.bytes.length == 4 &&
              c.bytes[2] == 0x05 &&
              c.source == CommandSource.controlPanel),
          isTrue,
        );

        // Playback drives the same store the live link does.
        final replay = container.read(replayProvider.notifier);
        await replay.play(path);
        try {
          await waitFor(
            () =>
                container.read(replayProvider).frames.isNotEmpty &&
                container.read(telemetryStoreProvider).replaying,
            reason: 'replay never went live',
          );
          replay.pause();
          expect(
              container.read(effectiveLaunchSiteProvider)?.name, 'E2E Pad');

          final frames = container.read(replayProvider).frames;
          replay.seek(container.read(replayProvider).durationMs ?? 0);
          expect(container.read(telemetryStoreProvider).packetCount,
              frames.length);
          expect(container.read(telemetryStoreProvider).latest!.sequence,
              frames.last.sequence);

          replay.seek(0);
          expect(container.read(telemetryStoreProvider).latest!.sequence,
              frames.first.sequence);
        } finally {
          replay.stop();
        }
        expect(container.read(replayProvider).isActive, isFalse);
        expect(
            container.read(telemetryStoreProvider).replaying, isFalse);
        expect(container.read(telemetryStoreProvider).history.isEmpty, isTrue);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('play drops the live link, stop stays disconnected', () async {
      final container = newContainer();
      final tempDir =
          await Directory.systemTemp.createTemp('trycatch_flows_drop_');
      try {
        await connectMock(container);
        final path =
            '${tempDir.path}${Platform.pathSeparator}drop_flight.bin';
        worker.send(StartRecordingCommand(
          filePath: path,
          launch: const LaunchRef(
            latitude: 50.0,
            longitude: 14.0,
            mslM: 300,
            name: 'Pad',
          ),
          connectorId: 'mock',
        ));
        await waitFor(
          () =>
              container.read(serialStatusProvider).value?.isRecording ?? false,
          reason: 'worker never reported recording',
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        worker.send(const StopRecordingCommand());
        await waitFor(
          () =>
              !(container.read(serialStatusProvider).value?.isRecording ??
                  true),
          reason: 'worker never stopped recording',
        );

        // Still connected here: play() itself drops the link.
        expect(
            container.read(serialStatusProvider).value?.isConnected, isTrue);
        final replay = container.read(replayProvider.notifier);
        await replay.play(path);
        try {
          await waitFor(
            () => container.read(replayProvider).frames.isNotEmpty,
            reason: 'replay never loaded',
          );
          // The disconnect round-trips the worker isolate, so it lands
          // just after the locally-decoded frames.
          await waitFor(
            () =>
                !(container.read(serialStatusProvider).value?.isConnected ??
                    true),
            reason: 'play() never dropped the live link',
          );
        } finally {
          replay.stop();
        }
        // No auto-reconnect: back to live means picking Connect again.
        expect(
            container.read(serialStatusProvider).value?.isConnected, isFalse);
        expect(container.read(telemetryStoreProvider).history.isEmpty, isTrue);
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('replay restores the pre-play connector choice', () async {
      final container = newContainer();
      final tempDir =
          await Directory.systemTemp.createTemp('trycatch_flows_conn_');
      try {
        // Park on segfault while disconnected, then play a mock file.
        await container
            .read(activeConnectorIdProvider.notifier)
            .set('segfault');
        expect(container.read(activeConnectorIdProvider).value, 'segfault');

        await connectMock(container);
        final path =
            '${tempDir.path}${Platform.pathSeparator}conn_flight.bin';
        worker.send(StartRecordingCommand(
          filePath: path,
          launch: const LaunchRef(
            latitude: 50.0,
            longitude: 14.0,
            mslM: 300,
            name: 'Pad',
          ),
          connectorId: 'mock',
        ));
        await waitFor(
          () =>
              container.read(serialStatusProvider).value?.isRecording ?? false,
          reason: 'worker never reported recording',
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        worker.send(const StopRecordingCommand());
        await waitFor(
          () =>
              !(container.read(serialStatusProvider).value?.isRecording ??
                  true),
          reason: 'worker never stopped recording',
        );
        await disconnect(container);

        final replay = container.read(replayProvider.notifier);
        await replay.play(path);
        try {
          await waitFor(
            () => container.read(replayProvider).frames.isNotEmpty,
            reason: 'replay never loaded',
          );
          expect(container.read(activeConnectorIdProvider).value, 'mock');
        } finally {
          replay.stop();
        }
        expect(
            container.read(activeConnectorIdProvider).value, 'segfault');
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });

  group('link-rate stability', () {
    test('MOCK-BQ dropout: no zero-heartbeats, no resume spike', () async {
      final container = newContainer();
      final config = container.read(serialConfigProvider.notifier);
      config.setPort('MOCK-BQ');
      config.connect();
      final arrivals = <({LinkStats snap, int atMs})>[];
      final sub = worker.linkStatsStream.listen((snap) => arrivals.add(
          (snap: snap, atMs: DateTime.now().millisecondsSinceEpoch)));
      try {
        await waitFor(
          () => container.read(serialStatusProvider).value?.isConnected ?? false,
          reason: 'MOCK-BQ never reported connected',
        );
        await waitFor(
          () => container.read(telemetryStoreProvider).packetCount > 0,
          reason: 'no live frames ingested',
        );
        // Ride into the ~5 s dropout: poll 2 s windows until the frame
        // count stalls inside one (windows straddling the dropout edge
        // still see pre-dropout traffic, so only a fully-stalled window
        // counts).
        var stalled = false;
        final stallDeadline =
            DateTime.now().add(const Duration(seconds: 16));
        while (!stalled) {
          if (DateTime.now().isAfter(stallDeadline)) break;
          final baseline =
              container.read(telemetryStoreProvider).packetCount;
          await Future<void>.delayed(const Duration(seconds: 2));
          stalled =
              container.read(telemetryStoreProvider).packetCount == baseline;
        }
        // Ride out: frames resume on the next cycle.
        final stalledAt =
            container.read(telemetryStoreProvider).packetCount;
        await waitFor(
          () =>
              container.read(telemetryStoreProvider).packetCount > stalledAt,
          reason: 'link never resumed after dropout',
          timeout: const Duration(seconds: 20),
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(stalled, isTrue, reason: 'never observed a dropout stall');
        expect(arrivals.length, greaterThan(2));
      } finally {
        await sub.cancel();
        await disconnect(container);
      }

      // Consecutive snapshots always carry new counters: silence emits
      // nothing, so the UI never charts 0.0 heartbeats mid-outage.
      bool sameCounters(LinkStats a, LinkStats b) =>
          a.totalBytes == b.totalBytes &&
          a.matchedBytes == b.matchedBytes &&
          a.garbageBytes == b.garbageBytes &&
          a.crcErrorBytes == b.crcErrorBytes &&
          a.matchedPackets == b.matchedPackets &&
          a.crcErrors == b.crcErrors;
      for (var i = 1; i < arrivals.length; i++) {
        expect(sameCounters(arrivals[i - 1].snap, arrivals[i].snap), isFalse,
            reason: 'zero-delta heartbeat at index $i');
      }

      // The outage surfaces as a snapshot gap, not zero samples.
      var maxGap = 0;
      for (var i = 1; i < arrivals.length; i++) {
        final gap = arrivals[i].atMs - arrivals[i - 1].atMs;
        if (gap > maxGap) maxGap = gap;
      }
      expect(maxGap, greaterThan(1500));

      // Replayed through the shared series, the resume carries no spike:
      // the outage delta spreads over the gap instead of one heartbeat.
      final series = RateSeries();
      var peak = 0.0;
      for (final a in arrivals) {
        final sample = series.addSnapshot(a.snap);
        if (sample != null && sample.packetRate > peak) {
          peak = sample.packetRate;
        }
      }
      expect(peak, lessThan(30.0));
    });
  });

  group('session scope', () {
    test('FlightReset clears telemetry, commands and channel together',
        () async {
      final container = newContainer();
      await connectMock(container);
      try {
        await waitFor(
          () => container.read(telemetryStoreProvider).packetCount > 0,
          reason: 'no live frames ingested',
        );
        container.read(serialConfigProvider.notifier).sendBytes(
            [0x54, 0x43, 0x05, 0x00],
            source: CommandSource.controlPanel);
        await waitFor(
          () =>
              container.read(commandLogProvider).isNotEmpty &&
              container.read(channelHealthProvider.notifier).series.isNotEmpty,
          reason: 'commands/channel history never accumulated',
          timeout: const Duration(seconds: 20),
        );
      } finally {
        await disconnect(container);
      }

      final ref = container.read(_refProvider);
      FlightReset.clearFlightRef(ref);

      expect(container.read(telemetryStoreProvider).history.isEmpty, isTrue);
      expect(container.read(telemetryStoreProvider).packetCount, 0);
      expect(container.read(commandLogProvider), isEmpty);
      expect(
          container.read(channelHealthProvider.notifier).series.isEmpty, isTrue);
    });

    test('switching connectors clears the live flight', () async {
      final container = newContainer();
      await connectMock(container);
      try {
        await waitFor(
          () => container.read(telemetryStoreProvider).packetCount > 0,
          reason: 'no live frames ingested',
        );
        // Segfault framing cannot parse the MOCK bytestream: the store must
        // drop stale frames instead of mixing vocabularies.
        await container
            .read(serialConfigProvider.notifier)
            .setConnector('segfault');
        expect(container.read(telemetryStoreProvider).history.isEmpty, isTrue);
        expect(container.read(telemetryStoreProvider).packetCount, 0);
      } finally {
        await disconnect(container);
      }
    });

    test('connector switch is ignored while recording', () async {
      final container = newContainer();
      final tempDir =
          await Directory.systemTemp.createTemp('trycatch_flows_lock_');
      try {
        await connectMock(container);
        final path =
            '${tempDir.path}${Platform.pathSeparator}lock_flight.bin';
        worker.send(StartRecordingCommand(
          filePath: path,
          launch: const LaunchRef(
            latitude: 50.0,
            longitude: 14.0,
            mslM: 300,
            name: 'Pad',
          ),
          connectorId: 'mock',
        ));
        await waitFor(
          () =>
              container.read(serialStatusProvider).value?.isRecording ?? false,
          reason: 'worker never reported recording',
        );
        await waitFor(
          () => container.read(telemetryStoreProvider).packetCount > 0,
          reason: 'no live frames ingested',
        );
        final packets =
            container.read(telemetryStoreProvider).packetCount;
        await container
            .read(serialConfigProvider.notifier)
            .setConnector('segfault');
        // Ignored: connector, flight and recording all untouched.
        expect(container.read(activeConnectorIdProvider).value, 'mock');
        expect(container.read(telemetryStoreProvider).packetCount,
            greaterThanOrEqualTo(packets));
        expect(
            container.read(serialStatusProvider).value?.isRecording, isTrue);
        worker.send(const StopRecordingCommand());
        await waitFor(
          () =>
              !(container.read(serialStatusProvider).value?.isRecording ??
                  true),
          reason: 'worker never stopped recording',
        );
        // The file kept one framing throughout: it replays cleanly.
        final loaded = await RecordingRepository.loadReplay(path);
        expect(loaded, isNotNull);
        expect(loaded!.frames.isNotEmpty, isTrue);
      } finally {
        await disconnect(container);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}

/// Exposes a [Ref] for APIs taking one (e.g. [FlightReset.clearFlightRef]).
final _refProvider = Provider((ref) => ref);

/// Fail-fast HTTP for tests: terrain tiles resolve to null without touching
/// the network or the platform tile cache.
class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FailingHttpClient();
}

class _FailingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      Future.error(const SocketException('offline test'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
