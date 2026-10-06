import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/core/app_config.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/core/channel_health.dart';
import 'package:trycatch/foundation/async_gate.dart';
import 'package:trycatch/ui/components/two_click_button.dart';

import '../tool/workspace_codegen.dart' show generateDefaults;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container() {
    final result = ProviderContainer(
      overrides: [
        telemetryStreamProvider.overrideWith((ref) => const Stream.empty()),
        serialStatusProvider.overrideWith(
          (ref) => Stream.value(const SerialWorkerStatus()),
        ),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  test('asset load failure terminates loading and remains closable', () async {
    final c = container();
    final replay = c.read(replayProvider.notifier);
    await replay.playAsset('assets/missing-regression.bin');
    expect(c.read(replayProvider).isLoading, isFalse);
    expect(c.read(replayProvider).errorMsg, contains('Could not load'));
    replay.clear();
    expect(c.read(replayProvider).isActive, isFalse);
  });

  test('session peaks and start survive history rollover and clear', () {
    final c = container();
    final store = c.read(telemetryStoreProvider.notifier);
    store.setReplaying(true);
    store.ingestFrames([
      const TelemetryFrame(
        receivedAtMs: 1000,
        baroAltitude: 1000,
        velocityUp: 100,
      ),
      for (var i = 0; i < AppConfig.telemetryHistoryCapacity; i++)
        TelemetryFrame(receivedAtMs: 1100 + i * 100, baroAltitude: 1),
    ]);
    final state = c.read(telemetryStoreProvider);
    expect(state.history.length, AppConfig.telemetryHistoryCapacity);
    expect(state.maxAltitude, 1000);
    expect(state.maxSpeed, 100);
    expect(state.firstPacketMs, 1000);
    store.clear();
    expect(c.read(telemetryStoreProvider).maxAltitude, 0);
    expect(c.read(telemetryStoreProvider).firstPacketMs, isNull);
    expect(c.read(telemetryStoreProvider).peaks.maxTotal, 0);
    store.clear();
  });

  test(
    'recording refuses an existing destination without modifying it',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'trycatch_regression_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/recording.bin');
      await file.writeAsString('previous recording');
      final recorder = Recorder();
      await expectLater(
        recorder.start(
          file.path,
          launch: const LaunchRef(latitude: 50, longitude: 14, mslM: 100),
          connectorId: 'mock',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'previous recording');
      expect(recorder.isRecording, isFalse);
    },
  );

  test('connection and port changes require a selected site', () {
    final c = ProviderContainer(
      overrides: [currentLaunchSiteProvider.overrideWithValue(null)],
    );
    addTearDown(c.dispose);
    final config = c.read(serialConfigProvider.notifier);
    config.setPort('MOCK');
    config.connect();
    config.refreshPorts();
    expect(c.read(serialConfigProvider).selectedPort, isNull);
    expect(c.read(serialConfigProvider).connectingPort, isNull);
    expect(c.read(serialConfigProvider).refreshPending, isFalse);
  });

  test('sparse timestamps produce a bounded profile', () {
    final packet = FrameCodec.encodePacket(const TelemetryFrame());
    final profile = buildChannelProfile([
      RecordingChunk(tsUs: 0, payload: packet),
      RecordingChunk(tsUs: 100000000000000, payload: packet),
    ]);
    expect(profile.length, lessThanOrEqualTo(20000));
    expect(profile.fold<int>(0, (sum, bin) => sum + bin.matchedPackets), 2);
    expect(
      () => buildChannelProfile([
        RecordingChunk(tsUs: 2000, payload: packet),
        RecordingChunk(tsUs: 1000, payload: packet),
      ]),
      throwsFormatException,
    );
  });

  test('decode gate releases its slot after a failure', () async {
    final gate = AsyncGate(1);
    final blocker = Completer<int>();
    final first = gate.run(() => blocker.future);
    var started = false;
    final second = gate.run(() async {
      started = true;
      return 2;
    });
    expect(started, isFalse);
    final failure = expectLater(first, throwsStateError);
    blocker.completeError(StateError('test failure'));
    await failure;
    expect(await second, 2);
  });

  test(
    'workspace codegen escapes arbitrary names and uses safe identifiers',
    () {
      final generated = generateDefaults({
        'workspaces': [
          {'name': '123 class\n"quote" \\path \$variable', 'root': null},
          {'name': '', 'root': null},
        ],
      });
      expect(generated, contains('workspace0()'));
      expect(generated, contains('workspace1()'));
      expect(generated, contains(r'\$variable'));
      expect(generated, contains(r'\n'));
      expect(generated, contains(r'\\path'));
    },
  );

  test('two-click confirmation switches armed action and disposes timers', () {
    final confirmation = TwoClickController<String>();
    var sends = 0;
    bool send() {
      sends++;
      return true;
    }

    confirmation.tap('a', send);
    confirmation.tap('b', send);
    expect(sends, 0);
    expect(confirmation.stateFor('a'), TwoClickState.idle);
    confirmation.tap('b', send);
    expect(sends, 1);
    expect(confirmation.stateFor('b'), TwoClickState.sent);
    confirmation.clear();
    confirmation.clear();
    confirmation.dispose();
  });

  test(
    'worker survives recording I/O failures and still streams telemetry',
    () async {
      final worker = await SerialWorker.spawn();
      addTearDown(worker.dispose);
      await worker.ready;
      final directory = await Directory.systemTemp.createTemp(
        'trycatch_bad_recording_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final error = worker.errorStream.first;
      worker.send(
        StartRecordingCommand(
          filePath: directory.path,
          launch: const LaunchRef(latitude: 50, longitude: 14, mslM: 100),
          connectorId: 'mock',
        ),
      );
      expect(
        (await error.timeout(const Duration(seconds: 5))).message,
        contains('Recording failed'),
      );
      expect(worker.currentStatus.isRecording, isFalse);
      final frame = worker.frameStream.first;
      worker.send(const ConnectCommand('MOCK'));
      expect(
        await frame.timeout(const Duration(seconds: 5)),
        isA<TelemetryFrame>(),
      );
      await worker.shutdown();
    },
  );

  test('graceful shutdown finalizes the recording and command log', () async {
    final worker = await SerialWorker.spawn();
    addTearDown(worker.dispose);
    await worker.ready;
    final directory = await Directory.systemTemp.createTemp(
      'trycatch_shutdown_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final frame = worker.frameStream.first;
    worker.send(const ConnectCommand('MOCK'));
    await frame.timeout(const Duration(seconds: 5));
    final path = '${directory.path}/flight.bin';
    final started = worker.statusStream.firstWhere((s) => s.isRecording);
    worker.send(
      StartRecordingCommand(
        filePath: path,
        launch: const LaunchRef(latitude: 50, longitude: 14, mslM: 100),
        connectorId: 'mock',
      ),
    );
    await started.timeout(const Duration(seconds: 5));
    await worker.frameStream
        .take(3)
        .toList()
        .timeout(const Duration(seconds: 5));
    final command = worker.commandStream.first;
    worker.send(
      SendBytesCommand(FrameCodec.encodePacket(const TelemetryFrame())),
    );
    await command.timeout(const Duration(seconds: 5));
    await worker.shutdown();
    await worker.shutdown();
    final header = await tryReadRecordingHeader(path);
    expect(header!.hasStats, isTrue);
    expect(header.packetCount, greaterThan(0));
    expect(await readRecordingCommands(path), hasLength(1));
  });
}
