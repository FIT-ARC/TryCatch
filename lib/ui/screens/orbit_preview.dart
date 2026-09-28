import 'dart:math' as math;

import 'package:dead_reckoning/dead_reckoning.dart' show metresPerDegreeLat;
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../services/flight_trim.dart';

/// Orbiting 3D flight-track preview for recording cards.
///
/// A lightweight echo of the satellite 3D view: the decoded GPS trail
/// (east/up/south metres, same handedness as the main scene) rendered with a
/// slowly orbiting camera over a faint ground grid — no network tiles, so a
/// grid full of cards stays cheap and works offline. Flat/empty tracks fall
/// back to the altitude sparkline (see [OrbitOrSparkline]).
class OrbitPreview extends StatefulWidget {
  final List<TrackPoint> track;

  const OrbitPreview({super.key, required this.track});

  @override
  State<OrbitPreview> createState() => _OrbitPreviewState();
}

class _OrbitPreviewState extends State<OrbitPreview>
    with SingleTickerProviderStateMixin {
  // Repaint driver only — the angle itself comes from the wall clock
  // (_syncedAzimuth), so every preview on screen shares one orbit phase.
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  )..repeat();

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Box size is needed for the one-time orbit fit — LayoutBuilder gives
    // it without a post-frame callback.
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _ensureFit(size);
        return AnimatedBuilder(
          animation: _orbit,
          builder: (context, _) => ClipRRect(
            // The painter is a free camera: perspective can throw points past
            // the box, so hard-clip instead of trusting the framing math.
            borderRadius: BorderRadius.circular(4),
            child: CustomPaint(
              painter: _OrbitPainter(
                track: widget.track,
                azimuth: _syncedAzimuth(),
                fitS: _fitS,
                fitTx: _fitTx,
                fitTy: _fitTy,
                trail: AppColors.seriesGpsTrack,
                pad: AppColors.pink,
                grid: AppColors.strongBorder,
                compass: AppColors.mutedForeground,
                skyTop: AppColors.muted,
                skyBottom: AppColors.card,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  /// Wall-clock orbit phase (16 s loop): identical for every preview at any
  /// instant, so a grid of cards rotates in sync. Per-card controller phases
  /// would drift apart within seconds.
  static double _syncedAzimuth() {
    const periodMs = 16000;
    return (DateTime.now().millisecondsSinceEpoch % periodMs) /
        periodMs *
        2 *
        math.pi;
  }
  // Best-fit framing, computed once per flight + box size and held for the
  // whole rotation: the union bbox over a full orbit sweep, so the zoom
  // never breathes as the silhouette changes (per-frame fitting shifts).
  double _fitS = 1.0, _fitTx = 0.0, _fitTy = 0.0;
  List<TrackPoint>? _fitTrack;
  Size? _fitSize;

  void _ensureFit(Size size) {
    if (size.width <= 0 ||
        size.height <= 0 ||
        (identical(widget.track, _fitTrack) && size == _fitSize)) {
      return;
    }
    final world = _buildWorld(widget.track);
    if (world == null) return;
    var minSx = double.infinity, maxSx = double.negativeInfinity;
    var minSy = double.infinity, maxSy = double.negativeInfinity;
    void feed(Offset? o) {
      if (o == null) return;
      if (o.dx < minSx) minSx = o.dx;
      if (o.dx > maxSx) maxSx = o.dx;
      if (o.dy < minSy) minSy = o.dy;
      if (o.dy > maxSy) maxSy = o.dy;
    }

    const sweeps = 16;
    for (var k = 0; k < sweeps; k++) {
      final project = _projector(world, size, k / sweeps * 2 * math.pi);
      for (final p in world.pts) {
        feed(project(p));
      }
      for (final r in [0.4, 0.8, 1.2]) {
        for (var i = 0; i < 24; i++) {
          final a = i / 24 * 2 * math.pi;
          feed(project(_Vec(world.padGround.x + world.span * r * math.cos(a),
              0, world.padGround.z + world.span * r * math.sin(a))));
        }
      }
    }
    if (!minSx.isFinite || (maxSx - minSx).abs() < 1e-6) return;
    final bw = math.max(maxSx - minSx, 1e-6);
    final bh = math.max(maxSy - minSy, 1e-6);
    _fitS = math.min(size.width * 0.88 / bw, size.height * 0.80 / bh)
        .clamp(0.15, 6.0);
    _fitTx = size.width / 2 - (minSx + maxSx) / 2 * _fitS;
    _fitTy = size.height * 0.42 - (minSy + maxSy) / 2 * _fitS;
    _fitTrack = widget.track;
    _fitSize = size;
  }
}

/// Picks the 3D orbit preview when the track is drawable, else the altitude
/// sparkline (no fix, single point, or decode that yielded altitudes only).
class OrbitOrSparkline extends StatelessWidget {
  final List<TrackPoint> track;
  final List<AltitudePoint> altProfile;

  const OrbitOrSparkline({
    super.key,
    required this.track,
    required this.altProfile,
  });

  @override
  Widget build(BuildContext context) {
    if (track.length >= 2) return OrbitPreview(track: track);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: CustomPaint(
        painter: _SparklinePainter(
          values: altProfile,
          color: AppColors.seriesAltitude,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Altitude sparkline thumbnail: min/max-normalised polyline + soft fill,
/// plotted against the flight clock so the profile keeps its real shape.
/// Flat/empty profiles render a quiet midline instead of crashing.
class _SparklinePainter extends CustomPainter {
  final List<AltitudePoint> values;
  final Color color;

  const _SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final p in values) {
      if (p.altitude < lo) lo = p.altitude;
      if (p.altitude > hi) hi = p.altitude;
    }
    if (!lo.isFinite || (hi - lo).abs() < 1e-9) {
      final y = size.height / 2;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 1.5,
      );
      return;
    }
    const pad = 3.0;
    final n = values.length;
    final spanMs = values.last.timeMs - values.first.timeMs;
    Offset pt(int i) {
      final xFrac = spanMs <= 0
          ? (n == 1 ? 0.5 : i / (n - 1))
          : (values[i].timeMs - values.first.timeMs) / spanMs;
      return Offset(
        pad + (size.width - 2 * pad) * xFrac,
        pad +
            (size.height - 2 * pad) *
                (1 - (values[i].altitude - lo) / (hi - lo)),
      );
    }
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    canvas.drawPath(
      Path.from(path)
        ..lineTo(pt(n - 1).dx, size.height)
        ..lineTo(pt(0).dx, size.height)
        ..close(),
      Paint()..color = color.withValues(alpha: 0.12),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      !identical(old.values, values) || old.color != color;
}

/// Cheap offline echo of the main flight scene's equirectangular projection
/// (see [worldFromLatLon] — same east/up/south handedness, own minimal math
/// so cards stay cheap and dependency-free).
class _Vec {
  final double x, y, z;
  const _Vec(this.x, this.y, this.z);
  _Vec operator -(_Vec o) => _Vec(x - o.x, y - o.y, z - o.z);
  _Vec operator +(_Vec o) => _Vec(x + o.x, y + o.y, z + o.z);
  double dot(_Vec o) => x * o.x + y * o.y + z * o.z;
  _Vec cross(_Vec o) => _Vec(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );
  double get len => math.sqrt(x * x + y * y + z * z);
  _Vec norm() {
    final l = len;
    return l < 1e-12 ? this : _Vec(x / l, y / l, z / l);
  }
}

/// World-space scene for one track: trail points (X east, Y up relative to
/// the lowest point, Z south — same handedness as the main flight scene),
/// pad ground point, overall span and orbit center.
class _World {
  final List<_Vec> pts;
  final _Vec padGround;
  final double span;
  final _Vec center;

  const _World({
    required this.pts,
    required this.padGround,
    required this.span,
    required this.center,
  });
}

/// Builds the world for [track], or `null` when too short to draw.
_World? _buildWorld(List<TrackPoint> track) {
  if (track.length < 2) return null;
  final lat0 = track.first.lat;
  final lon0 = track.first.lon;
  final cosLat0 = math.cos(lat0 * math.pi / 180);
  var minAlt = double.infinity;
  for (final p in track) {
    if (p.alt < minAlt) minAlt = p.alt;
  }
  final pts = [
    for (final p in track)
      _Vec(
        (p.lon - lon0) * metresPerDegreeLat * cosLat0,
        math.max(0.0, p.alt - minAlt),
        -(p.lat - lat0) * metresPerDegreeLat,
      ),
  ];

  var minX = double.infinity,
      maxX = double.negativeInfinity,
      minZ = double.infinity,
      maxZ = double.negativeInfinity,
      maxY = 0.0;
  for (final p in pts) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.z < minZ) minZ = p.z;
    if (p.z > maxZ) maxZ = p.z;
    if (p.y > maxY) maxY = p.y;
  }
  final span =
      math.max(math.max(maxX - minX, maxZ - minZ), math.max(maxY, 1.0));
  return _World(
    pts: pts,
    padGround: _Vec(pts.first.x, 0, pts.first.z),
    span: span,
    // Orbit axis through the launch site, not the trail's bbox center.
    center: _Vec(pts.first.x, 0, pts.first.z),
  );
}

/// Base perspective projection for [world] in [size] from [azimuth]
/// (fixed ~24° elevation). Shared by the one-time fit sweep and the painter.
Offset? Function(_Vec) _projector(_World world, Size size, double azimuth) {
  const el = 0.42; // ~24°
  final dist = world.span * 3.0 + 1.0;
  final cam = world.center +
      _Vec(math.sin(azimuth) * math.cos(el) * dist, math.sin(el) * dist,
          math.cos(azimuth) * math.cos(el) * dist);
  final fwd = (world.center - cam).norm();
  final right = fwd.cross(const _Vec(0, 1, 0)).norm();
  final up = right.cross(fwd);
  final focal = (math.min(size.width, size.height) * 0.5) / math.tan(0.35);
  return (_Vec p) {
    final v = p - cam;
    final z = v.dot(fwd);
    if (z < dist * 0.05) return null;
    return Offset(
      size.width / 2 + v.dot(right) / z * focal,
      size.height * 0.56 - v.dot(up) / z * focal,
    );
  };
}

class _OrbitPainter extends CustomPainter {
  final List<TrackPoint> track;
  final double azimuth;

  /// Fixed best-fit framing from the state's full-orbit sweep (never
  /// recomputed per frame, so the zoom can't breathe with rotation).
  final double fitS;
  final double fitTx;
  final double fitTy;

  final Color trail;
  final Color pad;
  final Color grid;
  final Color compass;
  final Color skyTop;
  final Color skyBottom;

  const _OrbitPainter({
    required this.track,
    required this.azimuth,
    required this.fitS,
    required this.fitTx,
    required this.fitTy,
    required this.trail,
    required this.pad,
    required this.grid,
    required this.compass,
    required this.skyTop,
    required this.skyBottom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final world = _buildWorld(track);
    if (world == null) return;
    final pts = world.pts;
    final padGround = world.padGround;
    final span = world.span;

    // Sky backdrop.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [skyTop, skyBottom],
        ).createShader(Offset.zero & size),
    );

    final project = _projector(world, size, azimuth);

    // Ground grid + trail runs in the base projection, drawn under the
    // fixed best-fit transform.
    final trailRuns = <List<Offset>>[];
    var run = <Offset>[];
    for (final p in pts) {
      final s = project(p);
      if (s == null) {
        if (run.length >= 2) trailRuns.add(run);
        run = <Offset>[];
      } else {
        run.add(s);
      }
    }
    if (run.length >= 2) trailRuns.add(run);

    // Grid rings as runs.
    final gridRuns = <List<Offset>>[];
    for (final r in [span * 0.4, span * 0.8, span * 1.2]) {
      var prev = project(_Vec(padGround.x + r, 0, padGround.z));
      var g = <Offset>[];
      if (prev != null) g.add(prev);
      for (var i = 1; i <= 40; i++) {
        final a = i / 40 * 2 * math.pi;
        final cur = project(_Vec(padGround.x + r * math.cos(a), 0,
            padGround.z + r * math.sin(a)));
        if (prev != null && cur != null) {
          g.add(cur);
        } else {
          if (g.length >= 2) gridRuns.add(g);
          g = <Offset>[];
        }
        prev = cur;
      }
      if (g.length >= 2) gridRuns.add(g);
    }
    final crossEnds = [
      project(_Vec(padGround.x - span * 1.3, 0, padGround.z)),
      project(_Vec(padGround.x + span * 1.3, 0, padGround.z)),
      project(_Vec(padGround.x, 0, padGround.z - span * 1.3)),
      project(_Vec(padGround.x, 0, padGround.z + span * 1.3)),
    ];

    // Fixed best-fit framing from the state's full-orbit sweep — the same
    // transform at every azimuth, so rotation never shifts the framing.
    canvas.save();
    canvas.translate(fitTx, fitTy);
    canvas.scale(fitS);
    // Inverse scale: strokes/dots stay constant on screen while the scene
    // zooms underneath.
    final iw = 1 / fitS;

    final gridPaint = Paint()
      ..color = grid.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = iw;
    void gridPath(List<Offset> g) {
      final path = Path()..moveTo(g.first.dx, g.first.dy);
      for (var i = 1; i < g.length; i++) {
        path.lineTo(g[i].dx, g[i].dy);
      }
      canvas.drawPath(path, gridPaint);
    }

    for (final g in gridRuns) {
      gridPath(g);
    }
    if (crossEnds[0] != null && crossEnds[1] != null) {
      canvas.drawLine(crossEnds[0]!, crossEnds[1]!, gridPaint);
    }
    if (crossEnds[2] != null && crossEnds[3] != null) {
      canvas.drawLine(crossEnds[2]!, crossEnds[3]!, gridPaint);
    }

    final trailPaint = Paint()
      ..color = trail
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * iw
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    for (final t in trailRuns) {
      final path = Path()..moveTo(t.first.dx, t.first.dy);
      for (var i = 1; i < t.length; i++) {
        path.lineTo(t[i].dx, t[i].dy);
      }
      canvas.drawPath(path, trailPaint);
    }

    // Pad marker + head (rocket) with a drop line to the ground.
    final padS = project(padGround);
    if (padS != null) {
      canvas.drawCircle(padS, 3 * iw,
          Paint()..color = pad.withValues(alpha: 0.9));
    }
    final head = pts.last;
    final headS = project(head);
    if (headS != null) {
      final footS = project(_Vec(head.x, 0, head.z));
      if (footS != null) {
        canvas.drawLine(
            headS,
            footS,
            Paint()
              ..color = trail.withValues(alpha: 0.4)
              ..strokeWidth = iw);
      }
      canvas.drawCircle(
          headS, 5 * iw, Paint()..color = trail.withValues(alpha: 0.25));
      canvas.drawCircle(
          headS, 2.5 * iw, Paint()..color = const Color(0xFFFFFFFF));
    }
    canvas.restore();

    // Compass: N (−Z) and E (+X) at the ends of the ground cross, drawn in
    // screen space so the labels stay readable at any zoom. World-locked,
    // so they swing around the pad with the orbit.
    void compassMark(_Vec end, String label) {
      final o = project(end);
      if (o == null) return;
      final at = Offset(o.dx * fitS + fitTx, o.dy * fitS + fitTy);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: compass,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }

    compassMark(
        _Vec(padGround.x, 0, padGround.z - span * 1.3), 'N');
    compassMark(
        _Vec(padGround.x + span * 1.3, 0, padGround.z), 'E');
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) =>
      old.azimuth != azimuth ||
      !identical(old.track, track) ||
      old.fitS != fitS ||
      old.fitTx != fitTx ||
      old.fitTy != fitTy ||
      old.trail != trail ||
      old.pad != pad ||
      old.grid != grid ||
      old.compass != compass ||
      old.skyTop != skyTop ||
      old.skyBottom != skyBottom;
}
