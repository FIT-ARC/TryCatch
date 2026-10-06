import 'dart:async';
import 'dart:collection';

/// Limits concurrent expensive jobs while preserving submission order.
class AsyncGate {
  final int capacity;
  final Queue<void Function()> _waiting = Queue();
  int _active = 0;
  AsyncGate(this.capacity) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }
  Future<T> run<T>(Future<T> Function() work) {
    final result = Completer<T>();
    _waiting.add(() async {
      try {
        result.complete(await work());
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _active--;
        _drain();
      }
    });
    _drain();
    return result.future;
  }

  void _drain() {
    while (_active < capacity && _waiting.isNotEmpty) {
      _active++;
      _waiting.removeFirst()();
    }
  }
}
