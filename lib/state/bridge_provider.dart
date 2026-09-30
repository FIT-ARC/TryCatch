import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../foundation/store.dart';
import '../services/live_bridge/bridge_config.dart';
import '../services/prefs_keys.dart';

/// Persisted configuration of the read-only live telemetry bridge.
///
/// Disabled by default on `127.0.0.1:6767` (see [BridgeConfig]): the public
/// website sits behind a reverse proxy, so the app itself never faces the
/// internet. Corrupt stored values fall back to [BridgeConfig] defaults.
final bridgeConfigProvider =
    AsyncNotifierProvider<BridgeConfigStore, BridgeConfig>(
  BridgeConfigStore.new,
);

class BridgeConfigStore extends JsonPersistedStore<BridgeConfig> {
  @override
  String get prefsKey => PrefsKeys.liveBridge;

  @override
  BridgeConfig get defaults => const BridgeConfig();

  @override
  Map<String, dynamic> toJson(BridgeConfig state) => state.toJson();

  @override
  BridgeConfig fromJson(Map<String, dynamic> json) =>
      BridgeConfig.fromJson(json);

  @override
  Future<BridgeConfig> build() => loadPersisted();

  Future<void> setEnabled(bool enabled) async {
    final current = state.value ?? defaults;
    if (current.enabled == enabled) return;
    await save(current.copyWith(enabled: enabled));
  }

  /// Stores [port] when it is a valid TCP port; returns whether it stuck.
  Future<bool> setPort(int port) async {
    if (!BridgeConfig.isValidPort(port)) return false;
    final current = state.value ?? defaults;
    if (current.port == port) return true;
    await save(current.copyWith(port: port));
    return true;
  }

  /// Stores [address] when non-empty; returns whether it stuck.
  Future<bool> setBindAddress(String address) async {
    if (!BridgeConfig.isValidBindAddress(address)) return false;
    final current = state.value ?? defaults;
    final trimmed = address.trim();
    if (current.bindAddress == trimmed) return true;
    await save(current.copyWith(bindAddress: trimmed));
    return true;
  }

  /// Stores [origin] when non-empty; returns whether it stuck.
  Future<bool> setCorsOrigin(String origin) async {
    if (origin.trim().isEmpty) return false;
    final current = state.value ?? defaults;
    final trimmed = origin.trim();
    if (current.corsOrigin == trimmed) return true;
    await save(current.copyWith(corsOrigin: trimmed));
    return true;
  }

  /// Re-saves the current value to retrigger listeners (bind retry after a
  /// bind failure, e.g. a port still held by a hot-restart orphan).
  Future<void> touch() async {
    await save(state.value ?? defaults);
  }
}

/// Runtime status of the bridge server (session state, never persisted).
class BridgeStatus {
  final bool running;
  final int port;
  final String bind;
  final int clients;
  final bool hasFrame;
  final String? error;

  const BridgeStatus({
    this.running = false,
    this.port = BridgeConfig.defaultPort,
    this.bind = BridgeConfig.defaultBindAddress,
    this.clients = 0,
    this.hasFrame = false,
    this.error,
  });

  /// Human address for status lines (`127.0.0.1:6767`).
  String get address => '$bind:$port';
}

/// Live status of the bridge isolate's HTTP server.
///
/// Infrastructure state, not flight state: [FlightReset] never touches it.
/// [clear] returns to stopped (relay teardown).
final bridgeStatusProvider =
    NotifierProvider<BridgeStatusStore, BridgeStatus>(
  BridgeStatusStore.new,
);

class BridgeStatusStore extends SessionStore<BridgeStatus> {
  @override
  BridgeStatus build() => const BridgeStatus();

  /// Replaces the status from a bridge isolate status message. Never throws.
  void report({
    required bool running,
    required int port,
    required String bind,
    required int clients,
    required bool hasFrame,
    String? error,
  }) {
    try {
      state = BridgeStatus(
        running: running,
        port: port,
        bind: bind,
        clients: clients,
        hasFrame: hasFrame,
        error: error,
      );
    } catch (_) {}
  }

  @override
  void clear() {
    try {
      state = const BridgeStatus();
    } catch (_) {}
  }
}
