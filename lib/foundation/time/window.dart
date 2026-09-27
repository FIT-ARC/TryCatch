import 'time_series.dart';

/// Exact mean rate of a cumulative counter over [window] ending at [nowMs]:
/// (last − first cumulative) ÷ span. Slice sizes don't matter, so emission
/// phase can't make it flicker (e.g. alternating 187 ms / 313 ms slices at
/// a true 10 Hz read exactly 10).
///
/// Generic over any [TimeSeries]: packets, bytes, anything cumulative.
/// Needs two in-window samples; otherwise returns [fallback].
double rateOverWindow<T>(
  TimeSeries<T> series,
  num Function(T) cumulativeOf, {
  int? nowMs,
  Duration window = const Duration(seconds: 2),
  double fallback = 0.0,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final from = now - window.inMilliseconds;
  T? first;
  T? last;
  for (var i = 0; i < series.length; i++) {
    final item = series.oldest(i);
    final ts = series.timestampOf(item);
    if (ts < from || ts > now) continue;
    first ??= item;
    last = item;
  }
  if (first == null || last == null || identical(first, last)) {
    return fallback;
  }
  final spanS =
      (series.timestampOf(last) - series.timestampOf(first)) / 1000.0;
  if (spanS <= 0) return fallback;
  return (cumulativeOf(last) - cumulativeOf(first)) / spanS;
}
