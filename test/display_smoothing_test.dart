import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';

const _site = LaunchSite(
  name: 'Pad',
  latitude: 49.799,
  longitude: 16.693,
  altitudeMsl: 403,
);

/// Frames on a slow eastward drift with 1e-5 deg quantization alternation
/// (the real wire grid: ~0.72 m steps at this latitude). Ascending state:
/// grounded (idle/armed) frames pin to pad height, which would collapse
/// this climb.
List<TelemetryFrame> driftFrames(int count) => [
      for (var i = 0; i < count; i++)
        TelemetryFrame(
          receivedAtMs: 1700000000000 + i * 40,
          flags: FrameFlags.gpsFix,
          sequence: i,
          latitude: 49.799,
          longitude: 16.693 + i * 0.2e-5 + (i.isEven ? 0.0 : 1e-5),
          baroAltitude: i * 0.5,
          accelX: 0,
          accelY: 0,
          accelZ: 9.81,
          fsmStateId: 2,
        ),
    ];

void main() {
  group('buildReplayScene', () {
    test('empty frames yield no scene', () {
      expect(
        buildReplayScene(frames: const [], positionMs: 0, site: _site),
        isNull,
      );
    });

    test('no fix and no site yields no scene', () {
      final frames = [
        const TelemetryFrame(receivedAtMs: 1700000000000),
      ];
      expect(
        buildReplayScene(frames: frames, positionMs: 0, site: null),
        isNull,
      );
    });

    test('smoothed rocket sits exactly on the trail tip', () {
      final frames = driftFrames(200);
      final scene = buildReplayScene(
        frames: frames,
        positionMs: 100 * 40,
        site: _site,
        smoothingEnabled: true,
      )!;
      expect(scene.trail, isNotEmpty);
      final tip = scene.trail.last;
      final d = (scene.rocketPos - tip).length;
      expect(d, closeTo(0.0, 1e-9));
    });

    test('raw rocket sits on the raw playhead fix', () {
      final frames = driftFrames(200);
      final scene = buildReplayScene(
        frames: frames,
        positionMs: 100 * 40,
        site: _site,
      )!;
      // Index 100 is even: no quantization offset, pure trend.
      final want = worldFromLatLon(
        49.799,
        16.693 + 100 * 0.2e-5,
        50.0,
        _site.latitude,
        _site.longitude,
        math.cos(49.799 * math.pi / 180),
      );
      expect((scene.rocketPos - want).length, closeTo(0.0, 1e-6));
    });

    test('smoothing damps the quantization staircase', () {
      final frames = driftFrames(200);
      const at = 100 * 40;
      final raw = buildReplayScene(
        frames: frames,
        positionMs: at,
        site: _site,
      )!;
      final smooth = buildReplayScene(
        frames: frames,
        positionMs: at,
        site: _site,
        smoothingEnabled: true,
      )!;
      // Wiggle = biggest horizontal step between consecutive trail points.
      // The head/tail ±35 of a centered average are edge transients (the
      // window is clamped there — the legacy app behaves identically), so
      // the smoothed line is judged on its interior.
      double worstStep(List<Vector3> trail, {int skipEnds = 0}) {
        var worst = 0.0;
        for (var i = skipEnds + 1; i < trail.length - skipEnds; i++) {
          worst = math.max(
            worst,
            (trail[i].x - trail[i - 1].x).abs(),
          );
        }
        return worst;
      }

      // Raw hops a full wire step (~0.72 m) point-to-point; the smoothed
      // interior advances by the drift slope only (~0.14 m).
      expect(worstStep(raw.trail), greaterThan(0.5));
      expect(worstStep(smooth.trail, skipEnds: 35), lessThan(0.2));
    });

    test('smoothed tip looks ahead into not-yet-played frames', () {
      // Pure ramp: a centered ±35 window over the full flight averages to
      // the center value even mid-replay.
      final frames = [
        for (var i = 0; i < 200; i++)
          TelemetryFrame(
            receivedAtMs: 1700000000000 + i * 40,
            flags: FrameFlags.gpsFix,
            latitude: 49.799,
            longitude: 16.693 + i * 1e-6,
            baroAltitude: 0,
            accelX: 0,
            accelY: 0,
            accelZ: 9.81,
          ),
      ];
      final scene = buildReplayScene(
        frames: frames,
        positionMs: 50 * 40,
        site: _site,
        smoothingEnabled: true,
      )!;
      final want = worldFromLatLon(
        49.799,
        16.693 + 50 * 1e-6,
        0,
        _site.latitude,
        _site.longitude,
        math.cos(49.799 * math.pi / 180),
      );
      expect((scene.rocketPos - want).length, closeTo(0.0, 1e-6));
    });

    test('whole flight stays addressable past the live ring bound', () {
      // 26k frames exceed the 9000-frame live ring; the replay trail must
      // still start at launch (first point within the ±35 head window of
      // the pad) and keep the tip.
      final frames = driftFrames(26000);
      final scene = buildReplayScene(
        frames: frames,
        positionMs: 25999 * 40,
        site: _site,
        smoothingEnabled: true,
      )!;
      expect(scene.trail.length, lessThanOrEqualTo(400));
      expect(scene.trail.first.x, lessThan(3.0));
      expect(
        (scene.rocketPos - scene.trail.last).length,
        closeTo(0.0, 1e-9),
      );
    });
  });

  group('smoothed replay attitude (recorded angles)', () {
    List<TelemetryFrame> attitudeFrames(
      int count,
      double Function(int i) pitchOf, {
      double Function(int i)? yawOf,
      double Function(int i)? rollOf,
    }) =>
        [
          for (var i = 0; i < count; i++)
            TelemetryFrame(
              receivedAtMs: 1700000000000 + i * 100,
              pitch: pitchOf(i),
              yaw: yawOf?.call(i) ?? 0,
              roll: rollOf?.call(i) ?? 0,
            ),
        ];

    test('follows recorded tilt instead of collapsing to vertical', () {
      // Regression: the smoother re-derived tilt from accelerometers and
      // forced yaw to 0, so any recording with level-ish specific force
      // rendered nose-up/north no matter what the flight computer reported.
      final frames = attitudeFrames(40, (_) => 30,
          yawOf: (_) => 90, rollOf: (_) => 10);
      final got = replayAttitude(
          frames: frames, positionMs: 2000, smoothingEnabled: true);
      expect(got.pitchDeg, closeTo(30, 1e-9));
      expect(got.yawDeg, closeTo(90, 1e-9));
      expect(got.rollDeg, closeTo(10, 1e-9));
    });

    test('tracks a canopy swing instead of cancelling it', () {
      // ±12° swing at a 2.8 s period (the MOCK chute): the short centered
      // window follows it at most of its amplitude; a multi-second window
      // would average whole periods away to vertical.
      final frames = attitudeFrames(
          100, (i) => 12 * math.sin(2 * math.pi * (i * 0.1) / 2.8));
      var peak = 0.0;
      for (var i = 0; i < 100; i++) {
        final got = replayAttitude(
            frames: frames, positionMs: i * 100, smoothingEnabled: true);
        peak = math.max(peak, got.pitchDeg.abs());
      }
      expect(peak, greaterThan(8.0));
    });

    test('yaw takes the short way around the wrap', () {
      final frames = attitudeFrames(40, (_) => 0,
          yawOf: (i) => i < 20 ? 350 : 10, rollOf: (_) => 0);
      final got = replayAttitude(
          frames: frames, positionMs: 1950, smoothingEnabled: true);
      // Circular mean of {350 ×n, 10 ×m} sits at/near 0 (or 360), never
      // mid-way at 180.
      final wrapped = ((got.yawDeg % 360) + 360) % 360;
      expect(wrapped < 30 || wrapped > 330, isTrue);
    });

    test('single-packet spikes melt away', () {
      final frames = attitudeFrames(40, (i) => i == 20 ? 45 : 5);
      final got = replayAttitude(
          frames: frames, positionMs: 2000, smoothingEnabled: true);
      // One 45° spike in a ±0.5 s window of 5° readings barely registers.
      expect(got.pitchDeg, lessThan(10.0));
    });
  });

  group('smoothed replay interpolation (low-rate recordings)', () {
    List<TelemetryFrame> fixes10Hz(int count) => [
          for (var i = 0; i < count; i++)
            TelemetryFrame(
              receivedAtMs: 1700000000000 + i * 100,
              flags: FrameFlags.gpsFix,
              latitude: 49.799,
              longitude: 16.693 + i * 1e-5,
              baroAltitude: i * 1.0,
              accelX: 0,
              accelY: 0,
              accelZ: 9.81,
              fsmStateId: 2,
            ),
        ];

    test('spline tip beats the chord on curves', () {
      // A 2 Hz arc (200 m radius): linear interpolation cuts the chord and
      // ticks through corners at every fix; the spline rounds them. The
      // sampled tip must sit nearer truth than the chord midpoint, and
      // exactly on the smoothed point at fix times.
      const r = 200.0;
      const omega = 20.0 / r;
      const mPerDeg = 111194.9;
      const cosLat = 0.6428; // cos(50 deg)
      double q(double v) => (v * 1e5).round() / 1e5;
      const site = LaunchSite(
        name: 'Pad',
        latitude: 50.0,
        longitude: 14.0,
        altitudeMsl: 400,
      );
      final frames = <TelemetryFrame>[];
      for (var i = 0; i < 60; i++) {
        final th = omega * (i * 0.5);
        frames.add(TelemetryFrame(
          receivedAtMs: 1700000000000 + (i * 500).round(),
          flags: FrameFlags.gpsFix,
          latitude: q(50.0 + r * (1 - math.cos(th)) / mPerDeg),
          longitude: q(14.0 + r * math.sin(th) / (mPerDeg * cosLat)),
          baroAltitude: 100,
        ));
      }
      Vector3 truth(double secs) {
        final th = omega * secs;
        return Vector3(
            r * math.sin(th), 100, -(r * (1 - math.cos(th))));
      }

      // At fix times the tip is exactly the smoothed point (no drift).
      final at = buildReplayScene(
        frames: frames,
        positionMs: 30 * 500,
        site: site,
        smoothingEnabled: true,
      )!;
      expect((at.rocketPos - at.trail.last).length, closeTo(0.0, 1e-9));
      // Between fixes the spline hugs the arc tighter than the chord.
      final s0 = buildReplayScene(
        frames: frames,
        positionMs: 30 * 500,
        site: site,
        smoothingEnabled: true,
      )!
          .rocketPos;
      final s1 = buildReplayScene(
        frames: frames,
        positionMs: 31 * 500,
        site: site,
        smoothingEnabled: true,
      )!
          .rocketPos;
      final mid = buildReplayScene(
        frames: frames,
        positionMs: 30 * 500 + 250,
        site: site,
        smoothingEnabled: true,
      )!
          .rocketPos;
      final chord = (s0 + s1) * 0.5;
      final want = truth(15.25);
      expect((mid - want).length, lessThan((chord - want).length));
      expect((mid - want).length, lessThan(2.0));
      // The rocket never detaches from the trail tip.
      final midScene = buildReplayScene(
        frames: frames,
        positionMs: 30 * 500 + 250,
        site: site,
        smoothingEnabled: true,
      )!;
      expect((midScene.rocketPos - midScene.trail.last).length,
          closeTo(0.0, 1e-9));
    });

    test('single-fix glitch despikes in place', () {
      // One 50 m GPS jump on an otherwise straight 10 Hz line: the median
      // stage kills it instead of smearing it through the mean window.
      final frames = [
        for (var i = 0; i < 40; i++)
          TelemetryFrame(
            receivedAtMs: 1700000000000 + i * 100,
            flags: FrameFlags.gpsFix,
            latitude: 49.799,
            longitude: 16.693 + (i == 20 ? 70e-5 : i * 1e-5),
            baroAltitude: 100,
          ),
      ];
      var worst = 0.0;
      // Interior only: at the flight ends the clamped window goes one-sided
      // and legitimately leads/lags truth by half a window.
      for (var i = 10; i < 30; i++) {
        final scene = buildReplayScene(
          frames: frames,
          positionMs: i * 100,
          site: _site,
          smoothingEnabled: true,
        )!;
        final want = worldFromLatLon(
          49.799,
          16.693 + i * 1e-5,
          100,
          _site.latitude,
          _site.longitude,
          math.cos(49.799 * math.pi / 180),
        );
        worst = math.max(worst, (scene.rocketPos - want).length);
      }
      expect(worst, lessThan(1.0));
    });

    test('raw position stays stepwise between fixes', () {
      final frames = fixes10Hz(20);
      final atFix = buildReplayScene(
        frames: frames,
        positionMs: 10 * 100,
        site: _site,
      )!;
      final mid = buildReplayScene(
        frames: frames,
        positionMs: 10 * 100 + 50,
        site: _site,
      )!;
      expect((mid.rocketPos - atFix.rocketPos).length, closeTo(0.0, 1e-9));
    });

    test('attitude holds steady values exactly when smoothed', () {
      final frames = [
        for (var i = 0; i < 40; i++)
          TelemetryFrame(
            receivedAtMs: 1700000000000 + i * 100,
            pitch: 12,
            yaw: 90,
            roll: 5,
          ),
      ];
      for (final at in [1900, 1950, 2000]) {
        final got = replayAttitude(
            frames: frames, positionMs: at, smoothingEnabled: true);
        expect(got.pitchDeg, closeTo(12, 1e-9));
        expect(got.yawDeg, closeTo(90, 1e-9));
        expect(got.rollDeg, closeTo(5, 1e-9));
      }
      final rawMid = replayAttitude(
          frames: frames, positionMs: 1950, smoothingEnabled: false);
      expect(rawMid.pitchDeg, closeTo(12, 1e-12));
    });

    test('attitude spline beats the chord on swings', () {
      // Heading swinging ±30° at a 5 s period, sampled at 10 Hz: halfway
      // between packets the spline sits nearer truth than the chord.
      double yawAt(double secs) => 90 + 30 * math.sin(2 * math.pi * secs / 5);
      final frames = [
        for (var i = 0; i < 60; i++)
          TelemetryFrame(
            receivedAtMs: 1700000000000 + i * 100,
            pitch: 5,
            yaw: yawAt(i * 0.1),
            roll: 0,
          ),
      ];
      double yawErr(int posMs) => (replayAttitude(
                  frames: frames, positionMs: posMs, smoothingEnabled: true)
              .yawDeg -
          yawAt(posMs / 1000))
          .abs();
      // Interior swing (away from clamped edges).
      expect(yawErr(3050), lessThan(1.5));
      final a = replayAttitude(
          frames: frames, positionMs: 3000, smoothingEnabled: true);
      final b = replayAttitude(
          frames: frames, positionMs: 3100, smoothingEnabled: true);
      final chordErr =
          (((a.yawDeg + b.yawDeg) / 2 - yawAt(3.05)).abs());
      expect(yawErr(3050), lessThan(chordErr));
    });

    test('low-rate arc stays on the arc when smoothed', () {
      // Regression: a fix-count window spans whole minutes at low GPS rates
      // and chord-cuts every curve (160 m off on this arc); the time window
      // keeps the tip on the flown line.
      const r = 200.0;
      const omega = 20.0 / r;
      const mPerDeg = 111194.9;
      const cosLat = 0.6428; // cos(50 deg)
      double q(double v) => (v * 1e5).round() / 1e5;
      final frames = <TelemetryFrame>[];
      for (var i = 0; i < 120; i++) {
        final th = omega * (i * 0.5);
        frames.add(TelemetryFrame(
          receivedAtMs: 1700000000000 + (i * 500).round(),
          flags: FrameFlags.gpsFix,
          latitude: q(50.0 + r * (1 - math.cos(th)) / mPerDeg),
          longitude: q(14.0 + r * math.sin(th) / (mPerDeg * cosLat)),
          baroAltitude: 100,
        ));
      }
      var worst = 0.0;
      // Interior only: at the flight ends the clamped window goes one-sided
      // and legitimately leads/lags truth by half a window.
      for (var i = 12; i < 108; i += 6) {
        final scene = buildReplayScene(
          frames: frames,
          positionMs: i * 500,
          site: const LaunchSite(
            name: 'Pad',
            latitude: 50.0,
            longitude: 14.0,
            altitudeMsl: 400,
          ),
          smoothingEnabled: true,
        )!;
        final th = omega * (i * 0.5);
        final want = Vector3(
            r * math.sin(th), 100, -(r * (1 - math.cos(th))));
        worst = math.max(worst, (scene.rocketPos - want).length);
      }
      expect(worst, lessThan(5.0));
    });

    test('display clock extrapolates while playing, frozen when paused', () {
      const base = ReplayState(
        filePath: 'f.bin',
        playing: true,
        speed: 1,
        positionMs: 1000,
        durationMs: 10000,
        positionWallMs: 5000,
      );
      expect(replayDisplayPositionMs(base, 5000), 1000);
      expect(replayDisplayPositionMs(base, 5050), 1050);
      const fast = ReplayState(
        filePath: 'f.bin',
        playing: true,
        speed: 4,
        positionMs: 1000,
        durationMs: 10000,
        positionWallMs: 5000,
      );
      expect(replayDisplayPositionMs(fast, 5025), 1100);
      expect(replayDisplayPositionMs(base, 5000 + 20000), 10000);
      const paused = ReplayState(
        filePath: 'f.bin',
        playing: false,
        positionMs: 1000,
        durationMs: 10000,
        positionWallMs: 5000,
      );
      expect(replayDisplayPositionMs(paused, 9000), 1000);
    });
  });
}
