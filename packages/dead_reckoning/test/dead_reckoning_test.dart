import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:test/test.dart';

DeadReckoningSample packet({
  int tMs = 0,
  double lat = 50,
  double lon = 14,
  double alt = 300,
  double vN = 0,
  double vE = 0,
  double vUp = 0,
  double accelZ = 0,
  double yaw = 0,
  double pitch = 0,
}) {
  return DeadReckoningSample(
    receivedAtMs: tMs,
    latitude: lat,
    longitude: lon,
    altitude: alt,
    velocityNorth: vN,
    velocityEast: vE,
    velocityUp: vUp,
    accelZ: accelZ,
    yaw: yaw,
    pitch: pitch,
  );
}

void main() {
  group('projectDeadReckoning', () {
    test('zero elapsed returns the packet', () {
      final p = projectDeadReckoning(
        last: packet(vN: 10, vUp: 5),
        elapsedS: 0,
      );
      expect(p.latitude, closeTo(50, 1e-12));
      expect(p.longitude, closeTo(14, 1e-12));
      expect(p.altitude, closeTo(300, 1e-9));
      expect(p.atMs, 0);
    });

    test('negative elapsed returns the packet', () {
      final p = projectDeadReckoning(
        last: packet(vN: 10),
        elapsedS: -2,
      );
      expect(p.latitude, closeTo(50, 1e-12));
      expect(p.altitude, closeTo(300, 1e-9));
    });

    test('hover holds position: thrust cancels gravity', () {
      // Sitting nose-up on the pad the accelerometer reads +9.81, which
      // cancels gravity exactly — no drift in any axis.
      final p = projectDeadReckoning(
        last: packet(alt: 500, accelZ: 9.80665),
        elapsedS: 10,
      );
      expect(p.latitude, closeTo(50, 1e-12));
      expect(p.longitude, closeTo(14, 1e-12));
      expect(p.altitude, closeTo(500, 1e-9));
      expect(p.atMs, 10000);
    });

    test('free fall drops at gravity', () {
      // Released from rest with a dead accelerometer: pure gravity arc.
      final p = projectDeadReckoning(
        last: packet(alt: 5000),
        elapsedS: 10,
      );
      expect(p.altitude, closeTo(5000 - 0.5 * 9.80665 * 100, 1e-9));
      expect(p.latitude, closeTo(50, 1e-12));
    });

    test('boost climbs on thrust minus gravity', () {
      // 40 m/s² up the nose, nose straight up: net ~30.2 m/s² up.
      final p = projectDeadReckoning(
        last: packet(alt: 5000, accelZ: 40),
        elapsedS: 2,
      );
      expect(p.altitude, closeTo(5000 + 0.5 * (40 - 9.80665) * 4, 1e-9));
    });

    test('horizontal accel follows the nose', () {
      // Full throttle horizontal, nose east: 500 m east in 10 s while
      // still falling at gravity (rockets make no lift).
      final p = projectDeadReckoning(
        last: packet(alt: 5000, accelZ: 10, yaw: 90, pitch: 90),
        elapsedS: 10,
      );
      expect(
        haversineDistanceM(50, 14, p.latitude, p.longitude),
        closeTo(500, 1.0),
      );
      expect(p.longitude, greaterThan(14));
      expect(p.latitude, closeTo(50, 1e-9));
      expect(p.altitude, closeTo(5000 - 0.5 * 9.80665 * 100, 1e-6));
    });

    test('velocity carries while accel holds the curve', () {
      // 10 m/s north, no thrust, high enough to stay airborne: constant
      // horizontal velocity plus the gravity drop.
      final p = projectDeadReckoning(
        last: packet(alt: 5000, vN: 10),
        elapsedS: 11,
      );
      expect(p.latitude, closeTo(50 + 110 / 111320, 1e-9));
      expect(p.altitude, closeTo(5000 - 0.5 * 9.80665 * 121, 1e-6));
    });

    test('diving rocket hits the plane and stops in place', () {
      final landed = projectDeadReckoning(
        last: packet(vE: 3, vUp: -6),
        elapsedS: 60,
      );
      expect(landed.altitude, 0);

      // Frozen: a later projection sits at the same touchdown point.
      final later = projectDeadReckoning(
        last: packet(vE: 3, vUp: -6),
        elapsedS: 600,
      );
      expect(later.altitude, 0);
      expect(later.latitude, closeTo(landed.latitude, 1e-12));
      expect(later.longitude, closeTo(landed.longitude, 1e-12));

      // ...which lies along the flown heading, short of unclamped drift.
      final dist =
          haversineDistanceM(50, 14, landed.latitude, landed.longitude);
      expect(dist, greaterThan(0));
      expect(dist, lessThan(3 * 60));
    });

    test('ascending rocket arcs over and lands', () {
      // 50 m/s up from 300 m: apex ≈ 428 m, back at 0 after ≈ 14.4 s.
      final apex = projectDeadReckoning(
        last: packet(vUp: 50),
        elapsedS: 50 / 9.80665,
      );
      expect(apex.altitude, closeTo(300 + 50 * 50 / 9.80665 / 2, 1e-6));

      final landed = projectDeadReckoning(
        last: packet(vUp: 50),
        elapsedS: 60,
      );
      expect(landed.altitude, 0);
    });

    test('packet below the plane holds at zero', () {
      final p = projectDeadReckoning(
        last: packet(alt: -5, vN: 10),
        elapsedS: 10,
      );
      expect(p.altitude, 0);
      expect(p.latitude, closeTo(50, 1e-12));
    });
  });

  group('geo', () {
    test('haversine matches known distance', () {
      // ~111.19 km per degree of latitude.
      final d = haversineDistanceM(50, 14, 51, 14);
      expect(d, closeTo(111190, 200));
    });

    test('offsetLatLon round-trips', () {
      final p = offsetLatLon(50.0755, 14.4378, northM: 500, eastM: -250);
      expect(p.latitude, greaterThan(50.0755));
      expect(p.longitude, lessThan(14.4378));
      expect(haversineDistanceM(50.0755, 14.4378, p.latitude, p.longitude),
          closeTo(559, 2));
    });
  });
}
