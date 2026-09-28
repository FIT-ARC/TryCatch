import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:serial/serial.dart';

/// Maps a decoded wire frame onto the projection's plain input sample.
///
/// Lives in the app (not in `package:dead_reckoning`) so the package stays
/// decoupled from the wire format.
DeadReckoningSample deadReckoningSampleFromFrame(TelemetryFrame frame) {
  return DeadReckoningSample(
    receivedAtMs: frame.receivedAtMs,
    latitude: frame.latitude,
    longitude: frame.longitude,
    gpsAltitude: frame.gpsAltitude,
    velocityNorth: frame.velocityNorth,
    velocityEast: frame.velocityEast,
    velocityDown: frame.velocityDown,
    accelZ: frame.accelZ,
    yaw: frame.yaw,
    pitch: frame.pitch,
    hasFix: frame.gpsHasFix,
  );
}
