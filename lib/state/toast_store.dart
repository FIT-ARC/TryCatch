import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../foundation/store.dart';

/// Severity of a toast notification. Maps to status colors + icons in
/// [ToastOverlay] — errors stay longest, info dismisses fastest.
enum ToastSeverity { info, success, warning, error }

/// One toast notification: a short human-readable message surfaced over the
/// workspace (serial errors, disconnects, failed uplinks...).
class ToastMessage {
  /// Stable id for dismiss/update (monotonic, see [ToastStore]).
  final int id;

  /// Short message body (1–2 lines).
  final String message;

  /// Optional bold title above the body (`null` hides the title row).
  final String? title;

  final ToastSeverity severity;

  /// Epoch millis when the toast was pushed (ordering + tests).
  final int timestampMs;

  const ToastMessage({
    required this.id,
    required this.message,
    required this.severity,
    this.title,
    required this.timestampMs,
  });
}

/// App-wide toast queue (Riverpod, no codegen).
///
/// The serial bridge ([SerialToastBridge]) and any other producer push here;
/// [ToastOverlay] renders the newest [maxVisible] and auto-dismisses each
/// card. Bounded to [maxEntries] so a flapping port can't grow memory.
final toastStoreProvider =
    NotifierProvider<ToastStore, List<ToastMessage>>(ToastStore.new);

class ToastStore extends SessionStore<List<ToastMessage>> {
  /// Visible cards in the overlay (newest last).
  static const int maxVisible = 4;

  /// Ring cap for the queue (the overlay only renders the tail).
  static const int maxEntries = 20;

  int _nextId = 0;

  @override
  List<ToastMessage> build() => const [];

  /// Pushes a toast; returns its id. Duplicate consecutive messages (same
  /// severity + text, e.g. a flapping watchdog) refresh the existing card
  /// instead of stacking.
  int push(String message,
      {ToastSeverity severity = ToastSeverity.error, String? title}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (state.isNotEmpty) {
      final last = state.last;
      if (last.message == message && last.severity == severity) {
        final refreshed = ToastMessage(
          id: last.id,
          message: last.message,
          severity: last.severity,
          title: title ?? last.title,
          timestampMs: now,
        );
        state = [...state.sublist(0, state.length - 1), refreshed];
        return last.id;
      }
    }
    final toast = ToastMessage(
      id: _nextId++,
      message: message,
      severity: severity,
      title: title,
      timestampMs: now,
    );
    var next = [...state, toast];
    if (next.length > maxEntries) {
      next = next.sublist(next.length - maxEntries);
    }
    state = next;
    return toast.id;
  }

  /// Dismisses the toast with [id] (no-op when unknown).
  void dismiss(int id) {
    if (!state.any((t) => t.id == id)) return;
    state = state.where((t) => t.id != id).toList();
  }

  /// Clears the whole queue (tests, reset flows).
  @override
  void clear() => state = const [];
}
