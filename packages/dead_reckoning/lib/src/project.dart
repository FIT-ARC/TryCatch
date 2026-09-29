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
/// packet's attitude, minus gravity — accelerometers read specific force
/// (+9.81 sitting nose-up on the pad), so gravity is removed to get
/// up-positive world acceleration. The ground is a flat plane at altitude
/// 0 (the pad): when the trajectory reaches it the rocket stops in place
/// (frozen at the touchdown point) instead of sinking through.
///
/// Pure function of its inputs — no state, no history, no terrain.
DeadReckoningPosition projectDeadReckoning({
  required DeadReckoningSample last,
  required double elapsedS,
}) {
  final dt = elapsedS < 0 ? 0.0 : elapsedS;
  final atMs = last.receivedAtMs + (dt * 1000).round();
  // Nothing to project from, or nowhere to go.
  if (last.altitude <= 0 || dt == 0) {
    return DeadReckoningPosition(
      latitude: last.latitude,
      longitude: last.longitude,
      altitude: math.max(0, last.altitude),
      atMs: atMs,
    );
  }
  // Nose direction (NEU) from attitude: yaw is the nose compass heading,
  // pitch its tilt away from vertical.
  final yaw = last.yaw * math.pi / 180;
  final pitch = last.pitch * math.pi / 180;
  final noseN = math.sin(pitch) * math.cos(yaw);
  final noseE = math.sin(pitch) * math.sin(yaw);
  final noseU = math.cos(pitch);
  // World-frame acceleration (up-positive): longitudinal specific force
  // along the nose, minus gravity.
  final aN = noseN * last.accelZ;
  final aE = noseE * last.accelZ;
  final aU = noseU * last.accelZ - deadReckoningGravity;
  // Time the vertical trajectory needs to reach altitude 0:
  // `½·a·t² + v·t + h0 = 0` — earliest non-negative root, if any.
  final vU = last.velocityUp;
  final h0 = last.altitude;
  var hitS = double.infinity;
  if (aU.abs() > 1e-9) {
    final discriminant = vU * vU - 2 * aU * h0;
    if (discriminant >= 0) {
      final root = math.sqrt(discriminant);
      for (final candidate in [(-vU - root) / aU, (-vU + root) / aU]) {
        if (candidate >= 0 && candidate < hitS) hitS = candidate;
      }
    }
  } else if (vU < 0) {
    hitS = -h0 / vU;
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
    altitude: math.max(0, h0 + (vU * t + 0.5 * aU * t * t)),
    atMs: atMs,
  );
}
