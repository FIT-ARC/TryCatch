import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('FlightSimulator', () {
    /// Steps the simulator at 10 Hz for [seconds] and returns all frames.
    List<TelemetryFrame> fly(FlightSimulator sim, double seconds) {
      const dt = 0.1;
      final frames = <TelemetryFrame>[];
      for (var t = 0.0; t < seconds; t += dt) {
        frames.add(sim.step(dt, timestampMs: (t * 1000).round()));
      }
      return frames;
    }

    test('produces a plausible full flight in phase order', () {
      final sim = FlightSimulator(seed: 7);
      final frames = fly(sim, 240); // 4 minutes covers the whole flight

      // Flight is over well before the end.
      expect(frames.last.fsmState, FsmState.landed);

      // Phase ordering: first occurrence indices must strictly increase.
      int idxOf(bool Function(TelemetryFrame) test) =>
          frames.indexWhere(test);
      final idle = idxOf((f) => f.fsmState == FsmState.idle);
      final armed = idxOf((f) => f.fsmState == FsmState.armed);
      final ascent = idxOf((f) => f.fsmState == FsmState.ascent);
      final apogee = idxOf((f) => f.fsmState == FsmState.apogee);
      final parachute = idxOf((f) => f.fsmState == FsmState.parachute);
      final landed = idxOf((f) => f.fsmState == FsmState.landed);

      expect(idle, greaterThanOrEqualTo(0));
      expect(armed, greaterThan(idle));
      expect(ascent, greaterThan(armed));
      expect(apogee, greaterThan(ascent));
      expect(parachute, greaterThan(apogee));
      expect(landed, greaterThan(parachute));
    });

    test('altitude never goes far below ground and apogee is realistic', () {
      final sim = FlightSimulator(seed: 3);
      final frames = fly(sim, 240);

      for (final f in frames) {
        expect(f.baroAltitude, greaterThan(-0.5));
        expect(f.baroAltitude.isFinite, isTrue);
      }

      final apogee = frames
          .map((f) => f.baroAltitude)
          .reduce((a, b) => a > b ? a : b);
      expect(apogee, greaterThan(400));
      expect(apogee, lessThan(2500));
    });

    test('peak velocity and acceleration occur during ascent', () {
      final sim = FlightSimulator(seed: 11);
      final frames = fly(sim, 240);

      final ascentFrames =
          frames.where((f) => f.fsmState == FsmState.ascent).toList();
      final maxAccel = frames
          .map((f) => f.accelTotal)
          .reduce((a, b) => a > b ? a : b);
      final maxAscentAccel = ascentFrames
          .map((f) => f.accelTotal)
          .reduce((a, b) => a > b ? a : b);

      // Peak specific force happens on the motor (~6.5 g).
      expect(maxAccel, closeTo(maxAscentAccel, 1.0));
      expect(maxAscentAccel, greaterThan(50));
      expect(maxAscentAccel, lessThan(90));

      final peakAscentSpeed = ascentFrames
          .map((f) => f.speedVertical)
          .reduce((a, b) => a > b ? a : b);
      expect(peakAscentSpeed, greaterThan(100)); // ~150 m/s at burnout
    });

    test('hall sensor reading jumps at apogee and stays high', () {
      final sim = FlightSimulator(seed: 5);
      final frames = fly(sim, 240);

      // Breakaway wire intact ≈ 2500, snapped ≈ 2950.
      const threshold = 2700;
      final firstTriggered =
          frames.indexWhere((f) => f.hallRaw > threshold);
      expect(firstTriggered, greaterThan(0));
      expect(frames[firstTriggered].fsmState, FsmState.apogee);

      for (final f in frames.skip(firstTriggered)) {
        expect(f.hallRaw, greaterThan(threshold));
      }
      for (final f in frames.take(firstTriggered)) {
        expect(f.hallRaw, lessThan(threshold));
      }
    });

    test('GPS has no fix during cold start, then stays near the launch site', () {
      final sim = FlightSimulator(latitude: 50.0755, longitude: 14.4378, seed: 2);
      final frames = fly(sim, 240);

      expect(frames.first.gpsHasFix, isFalse);
      expect(frames[30].gpsHasFix, isTrue);

      for (final f in frames) {
        expect((f.latitude - 50.0755).abs(), lessThan(0.01)); // ~1.1 km
        expect((f.longitude - 14.4378).abs(), lessThan(0.02));
      }
    });

    test('sequence numbers increment monotonically', () {
      final sim = FlightSimulator(seed: 13);
      final frames = fly(sim, 20);

      for (var i = 1; i < frames.length; i++) {
        expect(frames[i].sequence, frames[i - 1].sequence + 1);
      }
    });

    test('battery drains but stays in a plausible 2S LiPo range', () {
      final sim = FlightSimulator(seed: 17);
      final frames = fly(sim, 240);

      expect(frames.first.batteryVoltage, lessThanOrEqualTo(8.41));
      expect(frames.last.batteryVoltage, greaterThan(7.5));
      expect(frames.last.batteryVoltage, lessThan(frames.first.batteryVoltage));
    });

    test('descent rates match the parachute design points', () {
      final sim = FlightSimulator(seed: 19);
      final frames = fly(sim, 240);

      double avgSpeed(bool Function(TelemetryFrame) test) {
        final xs = frames.where(test).map((f) => f.speedVertical).toList();
        return xs.reduce((a, b) => a + b) / xs.length;
      }

      // Single canopy: ~6 m/s down throughout (measured away from
      // transitions).
      final highRate = avgSpeed((f) =>
          f.fsmState == FsmState.parachute && f.baroAltitude > 250);
      final lowRate = avgSpeed((f) =>
          f.fsmState == FsmState.parachute && f.baroAltitude < 100);

      expect(highRate, greaterThan(-10));
      expect(highRate, lessThan(-3));
      expect(lowRate, greaterThan(-10));
      expect(lowRate, lessThan(-3));
    });
  });
}
