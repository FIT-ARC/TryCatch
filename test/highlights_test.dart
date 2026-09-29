import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/ui/tiles/highlights_tile.dart';

TelemetryFrame frame({
  double n = 0,
  double e = 0,
  double u = 0,
  double ax = 0,
  double az = 0,
  double alt = 0,
  double lat = 0,
  double lon = 0,
  bool fix = false,
}) =>
    TelemetryFrame(
      velocityNorth: n,
      velocityEast: e,
      velocityUp: u,
      accelX: ax,
      accelZ: az,
      baroAltitude: alt,
      latitude: lat,
      longitude: lon,
      flags: fix ? FrameFlags.gpsFix : 0,
    );

void main() {
  test('scan picks ascent, descent, total speed, accel and altitude peaks', () {
    final peaks = FlightPeaks.scan([
      frame(n: 10, u: 50, ax: 3, az: 9.81, alt: 100),
      frame(e: 20, u: -40, ax: 30, az: 40, alt: 1058),
      frame(n: 5, u: 5, alt: 400),
    ]);

    expect(peaks.maxAscent, 50);
    expect(peaks.maxDescent, 40);
    expect(peaks.maxTotal, closeTo(50.99, 0.01));
    expect(peaks.maxAccel, 50); // sqrt(30² + 40²)
    expect(peaks.maxAltitude, 1058);
  });

  test('empty scan yields zeros', () {
    final peaks = FlightPeaks.scan(const []);
    expect(peaks.maxAscent, 0);
    expect(peaks.maxDescent, 0);
    expect(peaks.maxTotal, 0);
    expect(peaks.maxAccel, 0);
    expect(peaks.maxAltitude, 0);
  });

  test('gForce and mach conversions', () {
    expect(FlightPeaks.gForce(9.80665), closeTo(1, 1e-9));
    expect(FlightPeaks.mach(343.0), closeTo(1, 1e-9));
  });

  test('lastFix returns the latest frame with a fix', () {
    final frames = [
      frame(lat: 50.0, lon: 14.0, fix: true),
      frame(lat: 51.0, lon: 15.0), // no fix — skipped
      frame(lat: 50.5, lon: 14.5, fix: true),
    ];
    final last = FlightPeaks.lastFix(frames);
    expect(last?.latitude, 50.5);
    expect(FlightPeaks.lastFix(const []), isNull);
    expect(FlightPeaks.lastFix([frame()]), isNull);
  });
}
