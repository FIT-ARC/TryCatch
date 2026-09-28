/// Stateless dead reckoning projection.
library;

import 'dart:math' as math;

import './geo.dart';
import './position.dart';
import './sample.dart';

/// Gravity (m/s², positive) added back to the accelerometer's specific
/// force to get world-frame acceleration.
const double deadReckoningGravity = 9.80665;

/// Projects [last] (the most recent packet) forward by [elapsedS] seconds:
/// last position + velocity·dt + ½·acceleration·dt².
///
/// Acceleration is the packet's longitudinal accelerometer channel (thrust
/// and drag act along the nose) rotated onto the nose direction from the
/// packet's attitude, plus gravity — accelerometers read specific force
/// (+9.81 sitting nose-up on the pad), so gravity is added back. The
/// ground is a flat plane at altitude 0: when the trajectory reaches it
/// the rocket stops in place (frozen at the touchdown point) instead of
/// sinking through.
///
/// Pure function of its inputs — no state, no history, no terrain.
DeadReckoningPosition projectDeadReckoning({
  required DeadReckoningSample last,
  required double elapsedS,
}) {
  final dt = elapsedS < 0 ? 0.0 : elapsedS;
  final atMs = last.receivedAtMs + (dt * 1000).round();
  // Nothing to project from, or nowhere to go.
  if (last.gpsAltitude <= 0 || dt == 0) {
    return DeadReckoningPosition(
      latitude: last.latitude,
      longitude: last.longitude,
      altitude: math.max(0, last.gpsAltitude),
      atMs: atMs,
    );
  }
  // Nose direction (NED) from attitude: yaw is the nose compass heading,
  // pitch its tilt away from vertical.
  final yaw = last.yaw * math.pi / 180;
  final pitch = last.pitch * math.pi / 180;
  final noseN = math.sin(pitch) * math.cos(yaw);
  final noseE = math.sin(pitch) * math.sin(yaw);
  final noseD = -math.cos(pitch);
  // World-frame acceleration (down-positive): longitudinal specific force
  // along the nose, plus gravity.
  final aN = noseN * last.accelZ;
  final aE = noseE * last.accelZ;
  final aD = noseD * last.accelZ + deadReckoningGravity;
  // Time the vertical trajectory needs to reach altitude 0:
  // `½·a·t² + v·t − h0 = 0` — earliest non-negative root, if any.
  final vD = last.velocityDown;
  final h0 = last.gpsAltitude;
  var hitS = double.infinity;
  if (aD.abs() > 1e-9) {
    final discriminant = vD * vD + 2 * aD * h0;
    if (discriminant >= 0) {
      final root = math.sqrt(discriminant);
      for (final candidate in [(-vD - root) / aD, (-vD + root) / aD]) {
        if (candidate >= 0 && candidate < hitS) hitS = candidate;
      }
    }
  } else if (vD > 0) {
    hitS = h0 / vD;
  }
  // Past the touchdown the rocket stops in place.
  final t = dt < hitS ? dt : hitS;
  final p = offsetLatLon(
    last.latitude,
    last.longitude,
    northM: last.velocityNorth * t + 0.5 * aN * t * t,
    eastM: last.velocityEast * t + 0.5 * aE * t * t,
  );
  return DeadReckoningPosition(
    latitude: p.latitude,
    longitude: p.longitude,
    altitude: math.max(0, h0 - (vD * t + 0.5 * aD * t * t)),
    atMs: atMs,
  );
}
