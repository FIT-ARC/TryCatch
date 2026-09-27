/// Shared 1-2-5 axis rounding. One implementation for all charts.
abstract final class AxisSteps {
  static double niceStep(double raw) {
    if (raw <= 0) return 1;
    var mag = 1.0;
    while (raw < mag) {
      mag /= 10;
    }
    while (raw >= mag * 10) {
      mag *= 10;
    }
    for (final m in [1.0, 2.0, 5.0, 10.0]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  static double snappedMax(double peak) {
    final step = niceStep(peak / 3);
    return (peak / step).ceilToDouble() * step;
  }

  static String compactLabel(double v) {
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }
}
