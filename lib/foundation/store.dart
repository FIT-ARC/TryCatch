import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Base for in-memory session state. One verb: [clear].
///
/// Subclasses hold flight/session buffers only (no disk I/O). [clear] drops
/// buffers, cancels timers, keeps config flags as documented per subclass.
/// Must be idempotent and never throw.
abstract class SessionStore<S> extends Notifier<S> {
  void clear();
}

/// Base for persisted state. One verb for factory reset: [resetToDefaults].
///
/// Subclasses declare [prefsKey], [defaults], [encode]/[decode]. All
/// SharedPreferences I/O, corrupt-data fallback, and save failure tolerance
/// live here so stores don't duplicate it.
abstract class PersistedStore<S> extends AsyncNotifier<S> {
  String get prefsKey;

  S get defaults;

  String encode(S state);

  /// Parses a stored string. Throws on corrupt data (caught -> [defaults]).
  S decode(String raw);

  /// Loads persisted state, falling back to [defaults] on missing/corrupt data.
  Future<S> loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.get(prefsKey);
      final raw = stored is String
          ? stored
          : stored is bool
          ? stored.toString()
          : null;
      if (raw == null) return defaults;
      return decode(raw);
    } catch (_) {
      return defaults;
    }
  }

  /// Writes [next] to memory + disk. Disk failure keeps memory state.
  Future<void> save(S next) async {
    state = AsyncData(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, encode(next));
    } catch (_) {
      // Non-fatal; memory state is authoritative.
    }
  }

  /// Memory-only update, no disk write (replay in-memory overrides).
  void stage(S next) => state = AsyncData(next);

  /// Raw disk helpers for stores with memory/disk split views (mock filter).
  Future<void> writeRaw(String raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, raw);
    } catch (_) {
      // Non-fatal; memory state is authoritative.
    }
  }

  Future<void> resetToDefaults() => save(defaults);
}

/// JSON convenience over [PersistedStore].
abstract class JsonPersistedStore<S> extends PersistedStore<S> {
  Map<String, dynamic> toJson(S state);

  S fromJson(Map<String, dynamic> json);

  @override
  String encode(S state) => jsonEncode(toJson(state));

  @override
  S decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('expected JSON object');
    }
    return fromJson(decoded);
  }
}

/// Shared periodic-timer handling for the three ticking stores.
///
/// Mix into a [SessionStore]/[Notifier]: [startTicker] replaces any live
/// timer, [stopTicker] cancels, [cancelOnDispose] wires [Ref.onDispose].
/// [clear] implementations must call [stopTicker] first.
mixin StoreTicker {
  Timer? _ticker;

  void startTicker(Duration interval, void Function() onTick) {
    stopTicker();
    _ticker = Timer.periodic(interval, (_) => onTick());
  }

  void stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void cancelOnDispose(Ref ref) {
    ref.onDispose(stopTicker);
  }
}
