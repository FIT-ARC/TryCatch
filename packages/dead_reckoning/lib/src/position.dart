/// Dead-reckoned position (WGS84 + MSL altitude).
library;

import 'package:meta/meta.dart';

/// Estimated position produced by [projectDeadReckoning].
@immutable
class DeadReckoningPosition {
  final double latitude;
  final double longitude;
  final double altitude;

  /// Estimate time (Unix epoch ms): the anchor time plus the projected
  /// elapsed seconds.
  final int atMs;

  const DeadReckoningPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.atMs,
  });

  @override
  String toString() =>
      'DeadReckoningPosition(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}, ${altitude.toStringAsFixed(1)}m)';
}
