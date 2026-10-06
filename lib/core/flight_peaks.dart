import 'package:serial/serial.dart';

/// Session extremes over a set of frames. Pure + unit-testable.
class FlightPeaks {
  final double maxAscent;
  final double maxDescent;
  final double maxTotal;
  final double maxAccel;
  final double maxAltitude;

  const FlightPeaks({
    required this.maxAscent,
    required this.maxDescent,
    required this.maxTotal,
    required this.maxAccel,
    required this.maxAltitude,
  });

  static const empty = FlightPeaks(
    maxAscent: 0,
    maxDescent: 0,
    maxTotal: 0,
    maxAccel: 0,
    maxAltitude: 0,
  );
  FlightPeaks add(TelemetryFrame frame) {
    final single = scan([frame]);
    double max(double a, double b) => a > b ? a : b;
    return FlightPeaks(
      maxAscent: max(maxAscent, single.maxAscent),
      maxDescent: max(maxDescent, single.maxDescent),
      maxTotal: max(maxTotal, single.maxTotal),
      maxAccel: max(maxAccel, single.maxAccel),
      maxAltitude: max(maxAltitude, single.maxAltitude),
    );
  }

  static const double _g0 = 9.80665;

  /// Speed of sound at sea level, 15 °C — good enough for a Mach readout.
  static const double _speedOfSound = 343.0;

  static double gForce(double accelMs2) => accelMs2 / _g0;

  static double mach(double speedMs) => speedMs / _speedOfSound;

  static FlightPeaks scan(Iterable<TelemetryFrame> frames) {
    var ascent = 0.0;
    var descent = 0.0;
    var total = 0.0;
    var accel = 0.0;
    var altitude = 0.0;
    for (final f in frames) {
      if (f.speedVertical > ascent) ascent = f.speedVertical;
      if (-f.velocityUp > descent) descent = -f.velocityUp;
      if (f.speedTotal > total) total = f.speedTotal;
      if (f.accelTotal > accel) accel = f.accelTotal;
      if (f.baroAltitude > altitude) altitude = f.baroAltitude;
    }
    return FlightPeaks(
      maxAscent: ascent,
      maxDescent: descent,
      maxTotal: total,
      maxAccel: accel,
      maxAltitude: altitude,
    );
  }

  /// Last frame carrying a GPS fix, or `null` when there is none.
  static TelemetryFrame? lastFix(Iterable<TelemetryFrame> frames) {
    TelemetryFrame? last;
    for (final f in frames) {
      if (f.gpsHasFix) last = f;
    }
    return last;
  }
}
