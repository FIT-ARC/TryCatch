import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/telemetry_store.dart';

/// Regression test: seeking a large recording must be cheap and exact.
/// The old implementation replayed 0→target with per-packet state churn on
/// every slider tick (26k provider rebuilds per scrub on a full flight log).
/// The new one binary-searches the target and ingests forward deltas only.
void main() {
  group('ReplayController.seek', () {
    late Directory tempDir;
    late String path;
    late ProviderContainer container;

    const packetCount = 200;
    const stepUs = 40000;
    const baseUs = 1700000000000000;

    int tsUs(int i) => baseUs + i * stepUs;

    Future<void> writeRecording() async {
      final builder = BytesBuilder()
        ..add(const RecordingHeader(
          payloadLength: TelemetryFraming.payloadLength,
          hasLaunchSite: true,
          hasStats: true,
          launchLatitude: 49.799,
          launchLongitude: 16.693,
          launchMslM: 403,
          launchName: 'Pad',
          connectorId: 'mock',
        ).encode());
      for (var i = 0; i < packetCount; i++) {
        final packet = FrameCodec.encodePacket(
          TelemetryFrame(sequence: i, baroAltitude: i.toDouble()),
        );
        builder.add((ByteData(12)
              ..setInt64(0, tsUs(i), Endian.big)
              ..setUint32(8, packet.length, Endian.big))
            .buffer
            .asUint8List());
        builder.add(packet);
      }
      await File(path).writeAsBytes(builder.toBytes());
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('trycatch_seek_test_');
      path =
          '${tempDir.path}${Platform.pathSeparator}seek_recording.bin';
      await writeRecording();
      container = ProviderContainer(overrides: [
        telemetryStreamProvider
            .overrideWith((ref) => Stream<TelemetryFrame>.empty()),
        serialStatusProvider.overrideWith(
            (ref) => Stream.value(const SerialWorkerStatus())),
      ]);
      addTearDown(container.dispose);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    TelemetryState storeState() =>
        container.read(telemetryStoreProvider);

    Future<ReplayController> loadAndPark() async {
      final controller = container.read(replayProvider.notifier);
      await controller.play(path);
      controller.pause();
      controller.seek(0);
      return controller;
    }

    test('loads all frames and parks at zero (incl. the t=0 packet)',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).frames.length, packetCount);
      // positionMs 0 still contains the packet stamped exactly at start.
      expect(storeState().history.length, 1);
      expect(storeState().latest!.sequence, 0);
      expect(storeState().packetCount, 1);
      expect(controller.debugIndex, 1);
    });

    test('direct, forward and backward seeks agree exactly', () async {
      final controller = await loadAndPark();

      int relMs(int i) => (tsUs(i) - baseUs) ~/ 1000;

      controller.seek(relMs(100));
      expect(storeState().history.length, 101);
      expect(storeState().latest!.sequence, 100);
      expect(storeState().packetCount, 101);
      expect(controller.debugIndex, 101);

      // Small forward step ingests only the delta.
      controller.seek(relMs(102));
      expect(storeState().history.length, 103);
      expect(storeState().latest!.sequence, 102);
      expect(storeState().packetCount, 103);

      // Backward jump replays from the start with the same result.
      controller.seek(relMs(50));
      expect(storeState().history.length, 51);
      expect(storeState().latest!.sequence, 50);
      expect(storeState().packetCount, 51);

      // Past-the-end parks at the final frame.
      controller.seek(relMs(packetCount) + 100000);
      expect(storeState().history.length, packetCount);
      expect(storeState().latest!.sequence, packetCount - 1);
    });

    test('smoothing flag defaults off, toggles, and survives reload',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).smoothingEnabled, isFalse);
      controller.setSmoothing(true);
      expect(container.read(replayProvider).smoothingEnabled, isTrue);
      await controller.play(path);
      controller.pause();
      expect(container.read(replayProvider).smoothingEnabled, isTrue);
    });

    test('transport toggle flips actual playback and never strands it',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).playing, isFalse);

      controller.toggle();
      expect(container.read(replayProvider).playing, isTrue);

      // A second resume is idempotent, not a second ticker.
      controller.resume();
      expect(container.read(replayProvider).playing, isTrue);

      controller.toggle();
      expect(container.read(replayProvider).playing, isFalse);

      // Pausing twice is harmless; toggle still recovers to playing.
      controller.pause();
      controller.toggle();
      expect(container.read(replayProvider).playing, isTrue);
      controller.pause();
    });

    test('loop flag defaults off, toggles, survives reload, resets on stop',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).loopEnabled, isFalse);
      controller.setLooping(true);
      expect(container.read(replayProvider).loopEnabled, isTrue);
      await controller.play(path);
      controller.pause();
      expect(container.read(replayProvider).loopEnabled, isTrue);
      controller.setLooping(false);
      expect(container.read(replayProvider).loopEnabled, isFalse);
      controller.stop();
      expect(container.read(replayProvider).loopEnabled, isFalse);
      expect(container.read(replayProvider).isActive, isFalse);
    });
  });

  group('ReplayController stepping', () {
    late Directory tempDir;
    late String stagedPath;
    late String idlePath;
    late ProviderContainer container;

    const packetCount = 200;
    const stepUs = 40000;
    const baseUs = 1700000000000000;

    int tsUs(int i) => baseUs + i * stepUs;
    int relMs(int i) => (tsUs(i) - baseUs) ~/ 1000;

    /// Packet states for a nominal flight: idle 0-9, armed 10-49, ascent
    /// 50-149, apogee 150-159, parachute 160-189, landed 190-199.
    int stagedState(int i) {
      if (i < 10) return 0;
      if (i < 50) return 1;
      if (i < 150) return 2;
      if (i < 160) return 3;
      if (i < 190) return 4;
      return 5;
    }

    Future<void> writeRecording(String filePath, int Function(int) stateOf) async {
      final builder = BytesBuilder()
        ..add(const RecordingHeader(
          payloadLength: TelemetryFraming.payloadLength,
          hasLaunchSite: true,
          hasStats: true,
          launchLatitude: 49.799,
          launchLongitude: 16.693,
          launchMslM: 403,
          launchName: 'Pad',
          connectorId: 'mock',
        ).encode());
      for (var i = 0; i < packetCount; i++) {
        final packet = FrameCodec.encodePacket(
          TelemetryFrame(
              sequence: i, baroAltitude: i.toDouble(), fsmStateId: stateOf(i)),
        );
        builder.add((ByteData(12)
              ..setInt64(0, tsUs(i), Endian.big)
              ..setUint32(8, packet.length, Endian.big))
            .buffer
            .asUint8List());
        builder.add(packet);
      }
      await File(filePath).writeAsBytes(builder.toBytes());
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('trycatch_step_test_');
      stagedPath =
          '${tempDir.path}${Platform.pathSeparator}step_staged.bin';
      idlePath = '${tempDir.path}${Platform.pathSeparator}step_idle.bin';
      await writeRecording(stagedPath, stagedState);
      await writeRecording(idlePath, (_) => 0);
      container = ProviderContainer(overrides: [
        telemetryStreamProvider
            .overrideWith((ref) => Stream<TelemetryFrame>.empty()),
        serialStatusProvider.overrideWith(
            (ref) => Stream.value(const SerialWorkerStatus())),
      ]);
      addTearDown(container.dispose);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    TelemetryState storeState() =>
        container.read(telemetryStoreProvider);

    int position() => container.read(replayProvider).positionMs;

    Future<ReplayController> loadAndPark(String filePath) async {
      final controller = container.read(replayProvider.notifier);
      await controller.play(filePath);
      controller.pause();
      controller.seek(0);
      return controller;
    }

    test('packets step one frame at a time and park at the ends', () async {
      final controller = await loadAndPark(stagedPath);

      controller.stepPacket(1);
      expect(position(), relMs(1));
      expect(storeState().latest!.sequence, 1);

      controller.stepPacket(1);
      expect(position(), relMs(2));
      expect(storeState().latest!.sequence, 2);

      controller.stepPacket(-1);
      expect(position(), relMs(1));
      expect(storeState().history.length, 2);
      expect(storeState().latest!.sequence, 1);

      controller.stepPacket(-1);
      expect(position(), 0);
      expect(storeState().history.length, 1);

      // Past the start parks at zero; zero direction is a no-op.
      controller.stepPacket(-1);
      expect(position(), 0);
      expect(controller.debugIndex, 1);
      controller.stepPacket(0);
      expect(position(), 0);

      // Past the last packet parks at the recording end.
      controller.seek(relMs(packetCount - 1));
      controller.stepPacket(1);
      expect(position(), relMs(packetCount - 1));
      expect(storeState().history.length, packetCount);
      expect(storeState().latest!.sequence, packetCount - 1);
    });

    test('seconds step by flight clock and clamp to the bounds', () async {
      final controller = await loadAndPark(stagedPath);

      controller.stepTime(1000);
      expect(position(), 1000);
      expect(storeState().latest!.sequence, 25);
      expect(storeState().history.length, 26);

      controller.stepTime(-1000);
      expect(position(), 0);

      controller.stepTime(-5000);
      expect(position(), 0);

      controller.stepTime(999999);
      expect(position(), relMs(packetCount - 1));
      expect(storeState().history.length, packetCount);
    });

    test('events walk the markers with start/end stops', () async {
      final controller = await loadAndPark(stagedPath);
      final events = container.read(replayFlightEventsProvider);
      expect(events.map((e) => e.positionMs), [2000, 6000, 6400, 7600]);

      controller.stepEvent(1, events);
      expect(position(), 2000);
      controller.stepEvent(1, events);
      expect(position(), 6000);
      controller.stepEvent(1, events);
      expect(position(), 6400);
      controller.stepEvent(1, events);
      expect(position(), 7600);
      // Past the last event parks at the recording end.
      controller.stepEvent(1, events);
      expect(position(), relMs(packetCount - 1));

      controller.stepEvent(-1, events);
      expect(position(), 7600);
      controller.stepEvent(-1, events);
      expect(position(), 6400);
      controller.stepEvent(-1, events);
      expect(position(), 6000);
      controller.stepEvent(-1, events);
      expect(position(), 2000);
      // Before the first event parks at the recording start.
      controller.stepEvent(-1, events);
      expect(position(), 0);

      // Between markers the strict neighbours win, never the current spot.
      controller.seek(3000);
      controller.stepEvent(-1, events);
      expect(position(), 2000);
      controller.seek(3000);
      controller.stepEvent(1, events);
      expect(position(), 6000);

      controller.stepEvent(0, events);
      expect(position(), 6000);
    });

    test('events on a transition-free flight jump start to end', () async {
      final controller = await loadAndPark(idlePath);
      expect(container.read(replayFlightEventsProvider), isEmpty);

      controller.stepEvent(1, const []);
      expect(position(), relMs(packetCount - 1));
      controller.stepEvent(-1, const []);
      expect(position(), 0);
    });

    test('prev-event grace skips the just-reached event while playing',
        () async {
      final controller = await loadAndPark(stagedPath);
      final events = container.read(replayFlightEventsProvider);
      expect(events.map((e) => e.positionMs), [2000, 6000, 6400, 7600]);

      // Paused: strict — an event just behind the clock is a valid target.
      controller.seek(6100);
      controller.stepEvent(-1, events);
      expect(position(), 6000);

      // Playing: the ticker advanced a little past the event the previous
      // press just reached, so it is skipped in favour of the one before.
      controller.state =
          controller.state.copyWith(playing: true, positionMs: 6100);
      controller.stepEvent(-1, events);
      expect(position(), 2000);

      // Only the closest event is skipped: with two milestones inside the
      // grace window the walk still advances one press at a time.
      controller.state =
          controller.state.copyWith(playing: true, positionMs: 6500);
      controller.stepEvent(-1, events);
      expect(position(), 6000);

      // Past the grace window the nearby event counts again: at the very
      // end the previous milestone is 6400 (strict would give 7600 only
      // when paused).
      controller.state =
          controller.state.copyWith(playing: true, positionMs: 7960);
      controller.stepEvent(-1, events);
      expect(position(), 6400);

      // Grace boundary: exactly 500 ms behind still skips, 501 does not.
      controller.state =
          controller.state.copyWith(playing: true, positionMs: 6900);
      controller.stepEvent(-1, events);
      expect(position(), 6000);
      controller.state =
          controller.state.copyWith(playing: true, positionMs: 6901);
      controller.stepEvent(-1, events);
      expect(position(), 6400);
    });
  });
}
