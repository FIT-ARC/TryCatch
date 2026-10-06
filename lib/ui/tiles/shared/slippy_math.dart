import 'dart:math' as math;

import 'package:dead_reckoning/dead_reckoning.dart' show metresPerDegreeLat;

/// Pure slippy-map math and 3D terrain projection geometry.
///
/// Unit-tested functions with zero Flutter UI dependencies.

// ── Pure slippy-map math ─────────────────────────────────────────────────────

/// Longitude → tile X at [zoom].
int satTileX(double lon, int zoom) {
  final n = 1 << zoom;
  return (((lon + 180) / 360 * n).floor()).clamp(0, n - 1);
}

/// Latitude → tile Y at [zoom].
int satTileY(double lat, int zoom) {
  final n = 1 << zoom;
  final rad = lat * math.pi / 180;
  final y =
      ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n)
          .floor();
  return y.clamp(0, n - 1);
}

/// West edge longitude of tile [x].
double satTileLonWest(int x, int zoom) => x / (1 << zoom) * 360 - 180;

/// North edge latitude of tile [y].
double satTileLatNorth(int y, int zoom) {
  final n = 1 << zoom;
  final latRad = math.atan(_sinh(math.pi * (1 - 2 * y / n)));
  return latRad * 180 / math.pi;
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

/// Smoothstep (0→1) for edge fades.
double smoothstep(double t) => t * t * (3 - 2 * t);

/// Metres per pixel of Web-Mercator tiles at [zoom] and [lat].
double satMetresPerPixel(double lat, int zoom) =>
    156543.03392 * math.cos(lat * math.pi / 180) / (1 << zoom);

/// Zoom whose tiles cover [halfMeters] (half-extent) at roughly
/// [targetPixels] across.
int satZoomForHalfMeters(
  double halfMeters,
  double lat, {
  int targetPixels = 4096,
}) {
  var zoom =
      (math.log(
                156543.03392 *
                    math.cos(lat * math.pi / 180) *
                    targetPixels /
                    (halfMeters * 2),
              ) /
              math.ln2)
          .round();
  return zoom.clamp(10, 19);
}

/// World (east/south metres around lat0/lon0) → UV fractions into the given
/// geo bounds. v=0 is the north edge (image row 0).
({double u, double v}) satUvFraction(
  double eastM,
  double southM,
  double lat0,
  double lon0,
  double cosLat0, {
  required double northLat,
  required double southLat,
  required double westLon,
  required double eastLon,
}) {
  final lon = lon0 + eastM / (metresPerDegreeLat * cosLat0);
  final lat = lat0 - southM / metresPerDegreeLat;
  final u = (lon - westLon) / (eastLon - westLon).clamp(1e-12, 360);
  final v = (northLat - lat) / (northLat - southLat).clamp(1e-12, 180);
  return (u: u, v: v);
}

// ── Ground Extents & Constants ───────────────────────────────────────────────

/// Fixed ground half-extent (m): 20×20 km around the launch site.
const double satFixedHalfMeters = 10000;

/// Half-extent (m) of the mid tier: central 10×10 km.
const double satMidHalfMeters = 5000;

/// Half-extent (m) of the pad tier: central 2.5×2.5 km.
const double satPadHalfMeters = 1250;

/// Outer context patch fetch parameters.
const int satOuterTargetPixels = 2048;
const int satOuterTileRadius = 4;

/// Mid tier patch fetch parameters.
const int satMidTargetPixels = 4096;
const int satMidTileRadius = 4;

/// Pad tier patch fetch parameters.
const int satPadTargetPixels = 4096;
const int satPadTileRadius = 3;

/// Rim-feather start fraction for drape tiers.
const double satFeatherStart = 0.7;

/// Rim-feather alpha for a drape node [distM] from the anchor inside a tier.
double satRimAlpha(double distM, double coverageHalfMeters) {
  final ft =
      ((distM / coverageHalfMeters - satFeatherStart) / (1 - satFeatherStart))
          .clamp(0.0, 1.0);
  return 1 - ft * ft * (3 - 2 * ft);
}
