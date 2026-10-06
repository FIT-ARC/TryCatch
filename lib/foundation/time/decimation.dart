import 'dart:math' as math;

import 'time_series.dart';

/// Decimation strategies. One function for charts, trails, thumbnails, maps.
enum Decimation { extremes, strideStable }

/// Reduces [series] to ~[maxPoints], preserving shape per [mode].
///
/// extremes: keeps per-bucket min/max per value fn (charts, spike-safe).
/// strideStable: start-anchored power-of-two stride, tip always kept
/// (trails/maps, no crawl as data grows).
List<T> decimate<T>(
  TimeSeries<T> series,
  int Function(T) bucketOf,
  List<double Function(T)> values, {
  int maxPoints = 400,
  Decimation mode = Decimation.extremes,
}) {
  final items = series.toChronological();
  if (items.isEmpty) return const [];
  if (mode == Decimation.strideStable) return _strideStable(items, maxPoints);
  if (values.isEmpty) return const [];
  return _extremes(items, bucketOf, values, series.timestampOf);
}

List<T> _extremes<T>(
  List<T> items,
  int Function(T) bucketOf,
  List<double Function(T)> values,
  int Function(T) timestampOf,
) {
  final out = <T>[];
  var cur = bucketOf(items.first);
  var mins = List<double>.filled(values.length, double.infinity);
  var maxs = List<double>.filled(values.length, double.negativeInfinity);
  var minF = List<T?>.filled(values.length, null);
  var maxF = List<T?>.filled(values.length, null);

  void flush() {
    final set = <T>{...minF.whereType<T>(), ...maxF.whereType<T>()};
    if (set.isEmpty) return;
    final sorted = set.toList()
      ..sort((a, b) => timestampOf(a).compareTo(timestampOf(b)));
    out.addAll(sorted);
  }

  for (final item in items) {
    final b = bucketOf(item);
    if (b != cur) {
      flush();
      cur = b;
      mins = List<double>.filled(values.length, double.infinity);
      maxs = List<double>.filled(values.length, double.negativeInfinity);
      minF = List<T?>.filled(values.length, null);
      maxF = List<T?>.filled(values.length, null);
    }
    for (var i = 0; i < values.length; i++) {
      final v = values[i](item);
      if (v < mins[i]) {
        mins[i] = v;
        minF[i] = item;
      }
      if (v > maxs[i]) {
        maxs[i] = v;
        maxF[i] = item;
      }
    }
  }
  flush();
  return out;
}

List<T> _strideStable<T>(List<T> items, int maxPoints) {
  return [
    for (final index in strideStableIndices(items.length, maxPoints))
      items[index],
  ];
}

/// Shared start-anchored sampling without copying a full prefix first.
Iterable<int> strideStableIndices(int length, int maxPoints) sync* {
  if (length <= 0) return;
  if (length <= maxPoints) {
    yield* Iterable<int>.generate(length);
    return;
  }
  final budget = math.max(2, maxPoints);
  var stride = 1;
  while (2 + (length - 2) ~/ stride > budget) {
    stride *= 2;
  }
  yield 0;
  for (var i = stride; i < length - 1; i += stride) {
    yield i;
  }
  if (length > 1) yield length - 1;
}
