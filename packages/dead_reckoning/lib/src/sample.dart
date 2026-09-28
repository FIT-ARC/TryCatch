/// Plain input snapshot for the dead reckoning projection.
///
/// Deliberately decoupled from the wire format (`TelemetryFrame` lives in
/// `package:serial` and this package must not depend on it): the app maps
/// its last known fix frame to a [DeadReckoningSample] via a thin adapter
/// and projects it forward with [projectDeadReckoning].
library;

import 'package:meta/meta.dart';

/// One velocity/position snapshot projected by [projectDeadReckoning].
@immutable
class DeadReckoningSample {
  /// Wall-clock time the sample was observed (Unix epoch, ms).
  final int receivedAtMs;

  /// WGS84 latitude in degrees.
  final double latitude;

  /// WGS84 longitude in degrees.
  final double longitude;

  /// Reported altitude in metres above mean sea level.
  final double gpsAltitude;

  /// North velocity in m/s (NED frame).
  final double velocityNorth;

  /// East velocity in m/s (NED frame).
  final double velocityEast;

  /// Down velocity in m/s (NED frame, positive towards the ground).
  final double velocityDown;

  /// Body-frame longitudinal (Z) accelerometer channel in m/s² (specific
  /// force: +9.81 sitting nose-up on the pad). The only accel channel the
  /// projection uses — thrust and drag act along the nose.
  final double accelZ;

  /// Nose compass heading in degrees [0, 360).
  final double yaw;

  /// Tilt away from vertical in degrees (0 = nose straight up).
  final double pitch;

  /// Whether the GPS reported a position fix for this sample.
  final bool hasFix;

  const DeadReckoningSample({
    required this.receivedAtMs,
    this.latitude = 0,
    this.longitude = 0,
    this.gpsAltitude = 0,
    this.velocityNorth = 0,
    this.velocityEast = 0,
    this.velocityDown = 0,
    this.accelZ = 0,
    this.yaw = 0,
    this.pitch = 0,
    this.hasFix = true,
  });
}
