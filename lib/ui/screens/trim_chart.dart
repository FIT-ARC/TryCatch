import 'package:flutter/material.dart';

import '../../core/flight_events.dart';
import '../../core/format.dart';
import '../../services/flight_trim.dart' show AltitudePoint;
import '../../theme/app_colors.dart';
import '../components/flight_event_style.dart';

/// Trim preview: the full altitude profile dimmed, the kept window at full
/// strength with edge markers, plus flight-event dots on the curve.
///
/// Public (not `_`-private) so widget tests can pump it directly — the
/// surrounding card/dialog touch the filesystem and can't run in the
/// fake-async test zone.
class TrimChart extends StatelessWidget {
  final List<AltitudePoint> values;
  final List<FlightEvent> events;
  final int totalMs;
  final int startMs;
  final int endMs;
  final Color color;

  /// Diameter of one event dot on the trim chart.
  static const double dotSize = 14;

  const TrimChart({
    super.key,
    required this.values,
    required this.events,
    required this.totalMs,
    required this.startMs,
    required this.endMs,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final startFrac = totalMs <= 0
        ? 0.0
        : (startMs / totalMs).clamp(0.0, 1.0).toDouble();
    final endFrac = totalMs <= 0
        ? 1.0
        : (endMs / totalMs).clamp(0.0, 1.0).toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _TrimChartPainter(
                  values: values,
                  totalMs: totalMs,
                  startFrac: startFrac,
                  endFrac: endFrac,
                  color: color,
                ),
              ),
            ),
            for (final dot in _placeDots(w, h))
              Positioned(
                left: dot.x - dotSize / 2,
                top: dot.y - dotSize / 2,
                width: dotSize,
                height: dotSize,
                child: Tooltip(
                  message:
                      '${dot.event.label} at ${formatMinSec(dot.event.positionMs)}'
                      '${dot.kept ? '' : ' — outside kept slice'}',
                  child: FlightEventDot(
                    type: dot.event.type,
                    size: dotSize,
                    dimmed: !dot.kept,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Resolves each event to a dot centre on the altitude curve: x from the
  /// flight-clock fraction (the same time base as the kept-window edges), y
  /// from the nearest profile point in time. Dots landing within one diameter
  /// of an earlier dot nudge downward so stacked markers never paint on top
  /// of each other; x (the true position) never moves.
  List<_TrimDot> _placeDots(double w, double h) {
    final dots = <_TrimDot>[];
    if (events.isEmpty ||
        totalMs <= 0 ||
        w <= 0 ||
        h <= 0 ||
        !_wHFinite(w, h)) {
      return dots;
    }
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final p in values) {
      if (p.altitude < lo) lo = p.altitude;
      if (p.altitude > hi) hi = p.altitude;
    }
    final flat = values.length < 2 || !lo.isFinite || (hi - lo).abs() < 1e-9;
    const pad = 4.0;
    double yAt(double frac) {
      if (flat) return h / 2;
      final targetMs = frac * totalMs;
      var idx = 0;
      var best = double.infinity;
      for (var i = 0; i < values.length; i++) {
        final d = (values[i].timeMs - targetMs).abs();
        if (d < best) {
          best = d;
          idx = i;
        }
      }
      return pad + (h - 2 * pad) * (1 - (values[idx].altitude - lo) / (hi - lo));
    }

    for (final event in events) {
      final frac = (event.positionMs / totalMs).clamp(0.0, 1.0).toDouble();
      var y = yAt(frac);
      // De-collide against already-placed dots (time order = list order).
      var nudges = 0;
      while (nudges < 2) {
        var collides = false;
        final x = pad + (w - 2 * pad) * frac;
        for (final other in dots) {
          final dx = x - other.x;
          final dy = y - other.y;
          if (dx * dx + dy * dy < dotSize * dotSize) {
            collides = true;
            break;
          }
        }
        if (!collides) break;
        y += dotSize;
        nudges++;
      }
      final x = pad + (w - 2 * pad) * frac;
      dots.add(
        _TrimDot(
          event: event,
          x: x.clamp(0.0, w),
          y: y.clamp(0.0, h),
          kept: event.positionMs >= startMs && event.positionMs <= endMs,
        ),
      );
    }
    return dots;
  }

  static bool _wHFinite(double w, double h) => w.isFinite && h.isFinite;
}

/// One trim-chart marker resolved to a pixel centre.
class _TrimDot {
  final FlightEvent event;
  final double x;
  final double y;
  final bool kept;

  const _TrimDot({
    required this.event,
    required this.x,
    required this.y,
    required this.kept,
  });
}

/// Paints the trim preview: the full altitude profile dimmed, the kept
/// window at full strength with edge markers. (Event dots are widgets
/// overlaid by [TrimChart], not paint, so they keep tooltips.)
class _TrimChartPainter extends CustomPainter {
  final List<AltitudePoint> values;
  final int totalMs;
  final double startFrac;
  final double endFrac;
  final Color color;

  const _TrimChartPainter({
    required this.values,
    required this.totalMs,
    required this.startFrac,
    required this.endFrac,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || values.length < 2) return;
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final p in values) {
      if (p.altitude < lo) lo = p.altitude;
      if (p.altitude > hi) hi = p.altitude;
    }
    if (!lo.isFinite || (hi - lo).abs() < 1e-9) return;
    const pad = 4.0;
    final n = values.length;
    Offset pt(int i) {
      final xFrac = totalMs <= 0
          ? (n == 1 ? 0.5 : i / (n - 1))
          : (values[i].timeMs / totalMs).clamp(0.0, 1.0);
      return Offset(
        pad + (size.width - 2 * pad) * xFrac,
        pad + (size.height - 2 * pad) * (1 - (values[i].altitude - lo) / (hi - lo)),
      );
    }
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;

    // Full profile, dimmed.
    canvas.drawPath(path, line..color = color.withValues(alpha: 0.3));

    // Kept window: shade + bright redraw clipped to it.
    final left = startFrac.clamp(0.0, 1.0) * size.width;
    final right = endFrac.clamp(0.0, 1.0) * size.width;
    canvas.drawRect(
      Rect.fromLTRB(left, 0, right, size.height),
      Paint()..color = color.withValues(alpha: 0.10),
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, 0, right, size.height));
    canvas.drawPath(path, line..color = color);
    canvas.restore();

    // Edge markers.
    final edge = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(left, 0), Offset(left, size.height), edge);
    canvas.drawLine(Offset(right, 0), Offset(right, size.height), edge);
  }

  @override
  bool shouldRepaint(covariant _TrimChartPainter old) =>
      !identical(old.values, values) ||
      old.totalMs != totalMs ||
      old.startFrac != startFrac ||
      old.endFrac != endFrac ||
      old.color != color;
}
