import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';

/// Legacy per-packet tilt formula (old ground-station decodePacket.ts),
/// the reference the smoothed helpers must agree with on clean data.
({double rollDeg, double pitchDeg}) legacyTilt(
  double ax,
  double ay,
  double az,
) =>
    (
      rollDeg: math.atan2(ay, az) * 180 / math.pi,
      pitchDeg:
          math.atan2(-ax, math.sqrt(ay * ay + az * az)) * 180 / math.pi,
    );

TelemetryFrame frameWithAccel(double ax, double ay, double az) =>
    TelemetryFrame(accelX: ax, accelY: ay, accelZ: az);

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

  group('smoothedAttitude', () {
    test('empty input yields level', () {
      expect(
        smoothedAttitude(const []),
        (rollDeg: 0.0, pitchDeg: 0.0),
      );
    });

    test('matches the legacy formula on a steady vector', () {
      const ax = -2.139;
      const ay = -2.239;
      const az = 31.75;
      final frames = [
        for (var i = 0; i < 25; i++) frameWithAccel(ax, ay, az),
      ];
      final got = smoothedAttitude(frames);
      final want = legacyTilt(ax, ay, az);
      expect(got.rollDeg, closeTo(want.rollDeg, 1e-9));
      expect(got.pitchDeg, closeTo(want.pitchDeg, 1e-9));
    });

    test('averages the vector, not the angles (stable near free-fall)', () {
      // Per-frame tilts swing wildly when |a| is small; the averaged vector
      // still points roughly up with a slight -x lean.
      final frames = <TelemetryFrame>[
        frameWithAccel(-3.0, 0.0, 0.5),
        frameWithAccel(1.0, 2.0, -0.5),
        frameWithAccel(-2.0, -2.0, 1.0),
        frameWithAccel(0.0, 1.0, 0.5),
      ];
      final got = smoothedAttitude(frames, window: 4);
      final want = legacyTilt(-1.0, 0.25, 0.375);
      expect(got.rollDeg, closeTo(want.rollDeg, 1e-9));
      expect(got.pitchDeg, closeTo(want.pitchDeg, 1e-9));
      expect(got.rollDeg.isFinite, isTrue);
      expect(got.pitchDeg.isFinite, isTrue);
    });

    test('uses only the trailing window', () {
      final frames = <TelemetryFrame>[
        for (var i = 0; i < 10; i++) frameWithAccel(0, 0, 9.81),
        for (var i = 0; i < 25; i++) frameWithAccel(9.81, 0, 0),
      ];
      final got = smoothedAttitude(frames);
      final want = legacyTilt(9.81, 0, 0);
      expect(got.rollDeg, closeTo(want.rollDeg, 1e-9));
      expect(got.pitchDeg, closeTo(want.pitchDeg, 1e-9));
    });
  });
}
