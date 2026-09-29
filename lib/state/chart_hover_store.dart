import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared replay hover position: seconds since launch, `null` when no chart
/// is hovered.
///
/// Replay-only: every whole-flight chart (telemetry time-series + channel
/// health) plots the same seconds-since-launch x domain, so one value syncs
/// them all. Each replay chart publishes its touched x here and renders its
/// own tooltip + markers at the shared x — hovering one graph lights up the
/// same instant on every other graph. Live charts keep their independent
/// built-in touches and never read this.
///
/// UI-only transient state (not flight data): it survives [FlightReset] and
/// needs no persistence. Stale values are harmless — live builds ignore it
/// and replay builds clamp it into their axis.
final chartHoverProvider =
    NotifierProvider<ChartHoverController, double?>(ChartHoverController.new);

class ChartHoverController extends Notifier<double?> {
  @override
  double? build() => null;

  void hover(double xSeconds) {
    if (state != xSeconds) state = xSeconds;
  }

  void clear() {
    if (state != null) state = null;
  }
}

/// Index of the sample nearest to [x] in ascending [xs].
///
/// Returns -1 when empty. Ties resolve to the earlier sample. Binary search,
/// so whole-flight lookups stay cheap on every pointer move.
int nearestIndexForX(List<double> xs, double x) {
  if (xs.isEmpty) return -1;
  var lo = 0;
  var hi = xs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (xs[mid] < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo <= 0) return 0;
  if (lo >= xs.length) return xs.length - 1;
  return (x - xs[lo - 1]).abs() <= (xs[lo] - x).abs() ? lo - 1 : lo;
}
