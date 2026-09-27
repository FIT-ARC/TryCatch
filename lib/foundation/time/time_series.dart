import '../../core/ring_buffer.dart';

/// One time-series interface for live rings and full-flight lists.
///
/// Indexing is chronological only: 0 = oldest. Timestamp access goes through
/// [timestampOf] so external package types (TelemetryFrame, LinkStats bins)
/// work without modification.
abstract class TimeSeries<T> extends Iterable<T> {
  int timestampOf(T item);

  @override
  int get length;
  @override
  bool get isEmpty;
  @override
  bool get isNotEmpty => !isEmpty;

  T oldest(int index);
  T newest(int index);

  List<T> toChronological();
  List<T> slice(int startMs, int endMs);
  (List<T> played, List<T> future) splitAt(int clockMs);

  void clear();
}

/// Bounded live buffer. Drops oldest past [capacity].
class RingTimeSeries<T> extends TimeSeries<T> {
  final RingBuffer<T> _ring;
  final int Function(T) _timestampOf;

  RingTimeSeries(int capacity, int Function(T) timestampOf)
      : _ring = RingBuffer<T>(capacity),
        _timestampOf = timestampOf;

  @override
  int timestampOf(T item) => _timestampOf(item);

  @override
  int get length => _ring.length;

  @override
  bool get isEmpty => _ring.isEmpty;

  @override
  T oldest(int index) => _ring.getChronological(index);

  @override
  T newest(int index) => _ring[index];

  void push(T item) => _ring.push(item);

  void pushAll(Iterable<T> items) => _ring.pushAll(items);

  @override
  List<T> toChronological() => _ring.toList(growable: false);

  @override
  List<T> slice(int startMs, int endMs) => [
        for (var i = 0; i < _ring.length; i++)
          if (_timestampOf(_ring.getChronological(i)) >= startMs &&
              _timestampOf(_ring.getChronological(i)) <= endMs)
            _ring.getChronological(i),
      ];

  @override
  (List<T> played, List<T> future) splitAt(int clockMs) {
    final played = <T>[];
    final future = <T>[];
    for (var i = 0; i < _ring.length; i++) {
      final item = _ring.getChronological(i);
      if (_timestampOf(item) <= clockMs) {
        played.add(item);
      } else {
        future.add(item);
      }
    }
    return (played, future);
  }

  @override
  void clear() => _ring.clear();

  @override
  Iterator<T> get iterator => _ring.iterator;
}

/// Unbounded full-flight view over a decoded list (replay/preview).
class ListTimeSeries<T> extends TimeSeries<T> {
  List<T> _items;
  final int Function(T) _timestampOf;

  ListTimeSeries(int Function(T) timestampOf, [List<T>? items])
      : _timestampOf = timestampOf,
        _items = items ?? const [];

  set items(List<T> next) => _items = next;

  @override
  int timestampOf(T item) => _timestampOf(item);

  @override
  int get length => _items.length;

  @override
  bool get isEmpty => _items.isEmpty;

  @override
  T oldest(int index) => _items[index];

  @override
  T newest(int index) => _items[_items.length - 1 - index];

  @override
  List<T> toChronological() => List<T>.unmodifiable(_items);

  @override
  List<T> slice(int startMs, int endMs) => [
        for (final item in _items)
          if (_timestampOf(item) >= startMs && _timestampOf(item) <= endMs)
            item,
      ];

  @override
  (List<T> played, List<T> future) splitAt(int clockMs) {
    final played = <T>[];
    final future = <T>[];
    for (final item in _items) {
      if (_timestampOf(item) <= clockMs) {
        played.add(item);
      } else {
        future.add(item);
      }
    }
    return (played, future);
  }

  @override
  void clear() => _items = const [];

  @override
  Iterator<T> get iterator => _items.iterator;
}
