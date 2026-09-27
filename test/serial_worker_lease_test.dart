import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

/// Liveness-lease pins: child isolates survive a hot restart, so an
/// un-pinged worker must release its ports and exit on its own instead of
/// squatting on the serial link.
void main() {
  group('workerLeaseExpired', () {
    test('fires only past the lease', () {
      expect(
        workerLeaseExpired(lastSignalMs: 1000, nowMs: 1000 + workerLeaseMs),
        isFalse,
      );
      expect(
        workerLeaseExpired(lastSignalMs: 1000, nowMs: 1000 + workerLeaseMs + 1),
        isTrue,
      );
      expect(
        workerLeaseExpired(lastSignalMs: 5000, nowMs: 6000),
        isFalse,
      );
    });

    test('honours a custom lease', () {
      expect(
        workerLeaseExpired(lastSignalMs: 0, nowMs: 999, leaseMs: 1000),
        isFalse,
      );
      expect(
        workerLeaseExpired(lastSignalMs: 0, nowMs: 1001, leaseMs: 1000),
        isTrue,
      );
    });
  });

  group('unpinged worker', () {
    test('releases the link and goes silent', () async {
      final worker = await SerialWorker.spawn();
      addTearDown(worker.dispose);
      await worker.ready;

      // Bring a link up (proves the worker is alive and emitting).
      worker.send(const ConnectCommand('MOCK'));
      await worker.frameStream.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure('worker never emitted a frame'),
      );

      // Never pinged: after the lease the worker must report the link down
      // (observable here; dropped on the floor when the main is really
      // dead) and then go fully silent — no frames, no stats.
      final status = worker.statusStream
          .firstWhere((s) => !s.isConnected)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TestFailure(
              'unpinged worker never reported the link down',
            ),
          );
      await status;
      final strayFrames = await worker.frameStream
          .take(1)
          .toList()
          .timeout(
            const Duration(milliseconds: 1500),
            onTimeout: () => <TelemetryFrame>[],
          );
      expect(strayFrames, isEmpty,
          reason: 'worker still emitting after lease expiry');
      final strayStats = await worker.linkStatsStream
          .take(1)
          .toList()
          .timeout(
            const Duration(milliseconds: 1500),
            onTimeout: () => <LinkStats>[],
          );
      expect(strayStats, isEmpty,
          reason: 'worker stats tick still alive after lease expiry');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('restart handoff (old unpinged, new pinged)', () {
    test('old worker releases while the replacement stays live', () async {
      // Previous incarnation: live link, then its main "dies" (never
      // pinged again) — the hot-restart scenario.
      final oldWorker = await SerialWorker.spawn();
      addTearDown(oldWorker.dispose);
      await oldWorker.ready;
      oldWorker.send(const ConnectCommand('MOCK'));
      await oldWorker.frameStream.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure('old worker never emitted'),
      );

      // Replacement incarnation: pinged like the app does.
      final newWorker = await SerialWorker.spawn();
      addTearDown(newWorker.dispose);
      await newWorker.ready;
      final ping = Timer.periodic(
        const Duration(seconds: 2),
        (_) => newWorker.send(const PingCommand()),
      );
      addTearDown(ping.cancel);
      newWorker.send(const ConnectCommand('MOCK'));
      await newWorker.frameStream.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure('new worker never emitted'),
      );

      // The old worker's lease lapses: it must report the link down...
      await oldWorker.statusStream
          .firstWhere((s) => !s.isConnected)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TestFailure(
              'old worker never released the link',
            ),
          );
      // ...while the replacement keeps flowing on the same port name.
      await newWorker.frameStream.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TestFailure('replacement stalled'),
      );
      expect(newWorker.currentStatus.isConnected, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
