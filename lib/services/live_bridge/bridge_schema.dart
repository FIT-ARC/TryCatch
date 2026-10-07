import 'package:serial/serial.dart';

/// The public live telemetry packet, with altitude in metres MSL and AGL.
///
/// Staleness is age-based — the website compares `receivedAt` against now
/// (data older than a few seconds is stale). The bridge therefore emits no
/// markers: it just stops sending when the link drops, a replay runs, or
/// the buffers clear, and the last packet keeps its original `receivedAt`.
abstract final class LiveBridgeSchema {
  static Map<String, dynamic> packet({
    required TelemetryFrame frame,
    required double siteMslM,
    required double maxAltitudeAglM,
    required bool hasParachute,
  }) {
    return {
      'receivedAt': frame.receivedAtMs,
      'gpsLat': frame.latitude,
      'gpsLong': frame.longitude,
      'altitudeMSL': siteMslM + frame.baroAltitude,
      'altitudeAGL': frame.baroAltitude,
      'hasParachute': hasParachute,
      'maxAltitude': siteMslM + maxAltitudeAglM,
      'totalVelocity': frame.speedTotal,
    };
  }
}
