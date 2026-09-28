/// Pure time-correction mapping for converter-synthesized recordings.
///
/// Background: some legacy files carry a fabricated clock (exact 40 ms
/// grid from a round hour) with resampled duplicates. Given true-time
/// anchors (grid frame time → wall time from an independent log), this maps
/// every frame onto truth, collapses duplicate runs, and synthesizes
/// pre-launch pad frames from log rows the file never covered.
///
/// All time is integer milliseconds. Grid times are the file's own
/// `receivedAtMs` values; true times are wall-clock milliseconds.
library;

import 'package:serial/serial.dart';

/// One grid→truth correspondence.
class TimeAnchor {
  final int gridMs;
  final int trueMs;

  const TimeAnchor(this.gridMs, this.trueMs);
}

/// Enforces a usable mapping: strictly increasing grid times, scanning
/// backwards so collapsed regions resolve to their latest consistent time.
///
/// A resampled pad (hundreds of log rows matching one grid frame) would
/// otherwise map one grid instant to 25 minutes. Scanning from the end
/// keeps the last occurrence per grid value: the collapsed region anchors
/// at liftoff, and the earlier pad rows become prepend candidates instead.
List<TimeAnchor> enforceMonotonic(List<TimeAnchor> anchors) {
  final kept = <TimeAnchor>[];
  var minGrid = 1 << 62;
  for (var i = anchors.length - 1; i >= 0; i--) {
    final a = anchors[i];
    if (a.gridMs < minGrid) {
      kept.add(a);
      minGrid = a.gridMs;
    }
  }
  return kept.reversed.toList();
}

/// Maps [gridMs] onto true time by piecewise-linear interpolation.
/// Clamps below the first anchor; extrapolates past the last at the final
/// segment's slope (used for post-landing bench tails).
int mapGridToTrue(List<TimeAnchor> anchors, int gridMs) {
  assert(anchors.isNotEmpty, 'need at least one anchor');
  if (gridMs <= anchors.first.gridMs) return anchors.first.trueMs;
  for (var i = 1; i < anchors.length; i++) {
    final prev = anchors[i - 1];
    final next = anchors[i];
    if (gridMs <= next.gridMs) {
      final span = next.gridMs - prev.gridMs;
      if (span <= 0) return next.trueMs;
      final f = (gridMs - prev.gridMs) / span;
      return (prev.trueMs + f * (next.trueMs - prev.trueMs)).round();
    }
  }
  final prev = anchors[anchors.length - 2 < 0 ? 0 : anchors.length - 2];
  final last = anchors.last;
  final span = last.gridMs - prev.gridMs;
  if (span <= 0 || anchors.length < 2) return last.trueMs;
  final slope = (last.trueMs - prev.trueMs) / span;
  return (last.trueMs + slope * (gridMs - last.gridMs)).round();
}

/// OG firmware state id → MOCK connector state id, mirroring the original
/// converter (`00`/`01` pad → armed, `02` ascent, `04` parachute).
/// Returns `null` for states with no MOCK equivalent (row skipped).
int? ogFsmToMock(String og) => switch (og) {
      '00' || '01' => 1,
      '02' => 2,
      '04' => 4,
      _ => null,
    };

/// One decoded OG-log row positioned in truth time.
class CsvSiteSample {
  final int trueMs;
  final double latitude;
  final double longitude;
  final double baroAltitude;
  final double batteryVoltage;
  final String fsm;
  final double rollDeg;
  final double pitchDeg;

  const CsvSiteSample({
    required this.trueMs,
    required this.latitude,
    required this.longitude,
    required this.baroAltitude,
    required this.batteryVoltage,
    required this.fsm,
    required this.rollDeg,
    required this.pitchDeg,
  });
}

/// Pre-launch prologue: pad-idle rows strictly before [liftoffTrueMs].
/// Only `00`/`01` states inside the flight box qualify; anything else
/// (stray transitions, outliers) is left out.
List<CsvSiteSample> selectPadPrologue(
  List<CsvSiteSample> rows,
  int liftoffTrueMs, {
  double centerLat = 49.797,
  double centerLon = 16.697,
}) {
  return [
    for (final r in rows)
      if (r.trueMs < liftoffTrueMs &&
          (r.fsm == '00' || r.fsm == '01') &&
          (r.latitude - centerLat).abs() <= 0.02 &&
          (r.longitude - centerLon).abs() <= 0.02 &&
          r.baroAltitude >= -50 &&
          r.baroAltitude <= 50)
        r,
  ];
}

/// Synthesizes a pad-sit MOCK frame for a prologue row.
///
/// Position, baro, battery, attitude and time come from the row; dynamics
/// copy the file's own pad signature (a sitting rocket has no dynamics to
/// get wrong, and this keeps the splice seamless).
TelemetryFrame padFrameFrom({
  required CsvSiteSample row,
  required TelemetryFrame padSignature,
  required int sequence,
  required int fsmStateId,
}) {
  return TelemetryFrame(
    receivedAtMs: row.trueMs,
    flags: padSignature.flags,
    sequence: sequence,
    latitude: row.latitude,
    longitude: row.longitude,
    gpsAltitude: padSignature.gpsAltitude,
    baroAltitude: row.baroAltitude,
    velocityNorth: 0,
    velocityEast: 0,
    velocityDown: 0,
    accelX: padSignature.accelX,
    accelY: padSignature.accelY,
    accelZ: padSignature.accelZ,
    gyroX: padSignature.gyroX,
    gyroY: padSignature.gyroY,
    gyroZ: padSignature.gyroZ,
    heading: padSignature.heading,
    roll: row.rollDeg,
    pitch: row.pitchDeg,
    yaw: padSignature.yaw,
    batteryVoltage: row.batteryVoltage,
    hallRaw: padSignature.hallRaw,
    fsmStateId: fsmStateId,
  );
}
