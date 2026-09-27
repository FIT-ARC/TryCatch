import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../foundation/store.dart';
import '../services/prefs_keys.dart';

/// Stable id of the active telemetry connector (e.g. `'mock'`).
///
/// Persisted in [SharedPreferences]; unknown stored ids fall back to
/// [defaultConnectorId]. The settings toggle writes through [ConnectorIdStore.set];
/// replay playback overrides in memory ([persist] false) and restores on stop.
final activeConnectorIdProvider =
    AsyncNotifierProvider<ConnectorIdStore, String>(
  ConnectorIdStore.new,
);

/// The active [TelemetryConnector], resolved from [activeConnectorIdProvider].
///
/// Every connector-driven surface (FSM tile, control panel, command log,
/// flight events, capability gates) watches this: switching connectors
/// re-resolves states/commands/events/capabilities across the UI.
final activeConnectorProvider = Provider<TelemetryConnector>((ref) {
  final id = ref.watch(activeConnectorIdProvider).value ?? defaultConnectorId;
  return connectorById(id) ?? mockConnector;
});

class ConnectorIdStore extends PersistedStore<String> {
  @override
  String get prefsKey => PrefsKeys.connectorId;

  @override
  String get defaults => defaultVisibleConnectorId;

  @override
  String encode(String state) => state;

  @override
  String decode(String raw) {
    if (!isKnownConnectorId(raw)) throw const FormatException('unknown id');
    // The MOCK connector is dev-only: a release build that inherits a
    // persisted mock choice falls back to the visible default.
    if (!kDebugMode && isMockConnectorId(raw)) return defaultVisibleConnectorId;
    return raw;
  }

  @override
  Future<String> build() => loadPersisted();

  /// Selects the connector, persisting unless [persist] is false (replay's
  /// in-memory override). Unknown ids are ignored. The MOCK connector can
  /// only be *persisted* in debug builds; replay may still override to it
  /// in memory ([persist] false) so mock-stamped recordings replay in
  /// release.
  Future<void> set(String id, {bool persist = true}) async {
    if (!isKnownConnectorId(id)) return;
    if (persist && !kDebugMode && isMockConnectorId(id)) return;
    stage(id);
    if (!persist) return;
    await writeRaw(id);
  }
}
