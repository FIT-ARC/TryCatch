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
/// Subclasses declare [prefsKey], [defaults], [fromJson]/[toJson]. All
/// SharedPreferences I/O, corrupt-data fallback, and save failure tolerance
/// live here so stores don't duplicate it.
abstract class PersistedStore<S> extends AsyncNotifier<S> {
  String get prefsKey;

  S get defaults;

  S fromJson(Map<String, dynamic> json);

  Map<String, dynamic> toJson(S state);

  /// Loads persisted state, falling back to [defaults] on missing/corrupt data.
  Future<S> loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return defaults;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return defaults;
      return fromJson(decoded);
    } catch (_) {
      return defaults;
    }
  }

  /// Writes [next] to memory + disk. Disk failure keeps memory state.
  Future<void> save(S next) async {
    state = AsyncData(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(toJson(next)));
    } catch (_) {
      // Non-fatal; memory state is authoritative.
    }
  }

  Future<void> resetToDefaults() => save(defaults);
}

/// Shared periodic-timer handling for the three ticking stores.
///
/// Mix into a [SessionStore]/[Notifier]: [startTicker] replaces any live
/// timer, [stopTicker] cancels, [cancelOnDispose] wires [Ref.onDispose].
/// [clear] implementations must call [stopTicker] first.
mixin StoreTicker {
  Timer? _ticker;

  bool get tickerActive => _ticker?.isActive ?? false;

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
