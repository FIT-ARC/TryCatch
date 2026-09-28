/// Ground-side dead reckoning projection for model rocket telemetry.
///
/// Pure Dart (no Flutter, no serial link): the app projects its last known
/// GPS fix forward with [projectDeadReckoning] and reads back a
/// [DeadReckoningPosition].
library;

export 'src/geo.dart';
export 'src/position.dart';
export 'src/project.dart';
export 'src/sample.dart';
