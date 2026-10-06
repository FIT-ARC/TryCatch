import '../../state/connector_provider.dart';

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import './bridge_schema.dart';
import './bridge_server.dart';
import '../../session/feedback.dart';
import '../../state/bridge_provider.dart';
import '../../state/launch_site_store.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';

/// Headless relay: forks live frames into the bridge isolate.
///
/// Owned by liveBridgeRuntimeProvider for the app lifetime. The serial worker stays
/// the only isolate that touches ports and recordings; this relay only
/// copies already-decoded [TelemetryFrame]s from the main isolate into the
/// bridge over a [SendPort], latest-only with no queue — a slow public
/// client drops frames, the flight pipeline never blocks.
///
/// Forwarding is live-only: frames are skipped while a replay is active or
/// the link is down. The public packet carries `receivedAt`, so the website
/// treats data older than a few seconds as stale — no markers needed.
///
/// The relay pings the bridge every 2 s (see [bridgeLeaseMs]): a bridge
/// orphaned by a hot restart frees its socket and exits on its own, and the
/// relay retries binding while enabled and restarts unexpected isolate exits.
final liveBridgeRuntimeProvider = Provider<LiveBridgeRuntime>((ref) {
  final runtime = LiveBridgeRuntime(ref);
  runtime.start();
  runtime.listen();
  ref.onDispose(runtime.dispose);
  return runtime;
});

class LiveBridgeRuntime {
  final Ref ref;
  bool mounted = true;
  LiveBridgeRuntime(this.ref);
  Isolate? _isolate;
  SendPort? _bridge;
  ReceivePort? _fromBridge;
  StreamSubscription<dynamic>? _bridgeSub;
  final List<Map<String, dynamic>> _outbox = [];
  String? _lastError;
  Timer? _pingTimer;
  Timer? _retryTimer;

  void start() {
    _spawn();
    // Lease heartbeat (see [bridgeLeaseMs]): proves this main isolate is
    // alive so an orphaned bridge frees its socket and exits on its own.
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _send({LiveBridgeMessages.type: LiveBridgeMessages.ping});
    });
  }

  Future<void> _spawn() async {
    final fromBridge = ReceivePort();
    _fromBridge = fromBridge;
    _bridgeSub = fromBridge.listen(_onBridgeMessage);
    try {
      final isolate = await Isolate.spawn(
        liveBridgeMain,
        fromBridge.sendPort,
        debugName: 'LiveBridge',
        onError: fromBridge.sendPort,
        onExit: fromBridge.sendPort,
      );
      if (!mounted) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } catch (e) {
      if (!mounted) return;
      _bridgeSub?.cancel();
      fromBridge.close();
      ref
          .read(bridgeStatusProvider.notifier)
          .report(
            running: false,
            port: ref.read(bridgeConfigProvider).value?.port ?? 6767,
            bind:
                ref.read(bridgeConfigProvider).value?.bindAddress ??
                '127.0.0.1',
            clients: 0,
            hasFrame: false,
            error: '$e',
          );
      _onBridgeMessage(null);
    }
  }

  void _onBridgeMessage(dynamic message) {
    if (!mounted) return;
    if (message is! Map) {
      _bridge = null;
      _isolate = null;
      _bridgeSub?.cancel();
      _fromBridge?.close();
      _cancelRetry();
      _retryTimer = Timer(const Duration(seconds: 2), () {
        _retryTimer = null;
        if (mounted) _spawn();
      });
      return;
    }
    if (message[LiveBridgeMessages.type] == LiveBridgeMessages.ready) {
      final port = message['commandPort'];
      if (port is SendPort) {
        _bridge = port;
        var flushedConfig = false;
        for (final pending in _outbox) {
          if (pending[LiveBridgeMessages.type] == LiveBridgeMessages.config) {
            flushedConfig = true;
          }
          _bridge!.send(pending);
        }
        _outbox.clear();
        // The outbox may already hold the current config (queued before the
        // handshake); resending it would bind the same port twice.
        if (!flushedConfig) _sendConfig();
      }
      return;
    }
    if (message[LiveBridgeMessages.type] == LiveBridgeMessages.status) {
      final running = message['running'] == true;
      final port = message['port'];
      final bind = message['bind'];
      final clients = message['clients'];
      final hasFrame = message['hasFrame'] == true;
      final error = _friendlyError(
        message['error'] as String?,
        port is int ? port : 6767,
      );
      ref
          .read(bridgeStatusProvider.notifier)
          .report(
            running: running,
            port: port is int ? port : 6767,
            bind: bind is String ? bind : '127.0.0.1',
            clients: clients is int ? clients : 0,
            hasFrame: hasFrame,
            error: error,
          );
      if (error != null && error != _lastError) {
        ref.errorToast(error, title: 'Live output');
      }
      _lastError = error;
      if (error != null &&
          mounted &&
          (ref.read(bridgeConfigProvider).value?.enabled ?? false)) {
        _scheduleRetry();
      } else {
        _cancelRetry();
      }
    }
  }

  /// Translates the raw bind failure into a one-line status: the usual
  /// cause is a hot-restart orphan still holding the port, and the retry
  /// below frees it within seconds.
  String? _friendlyError(String? error, int port) {
    if (error == null) return null;
    if (error.contains('Failed to create server socket')) {
      return 'Port $port is busy — retrying automatically';
    }
    return error;
  }

  /// Re-sends the config until the bind succeeds (hot-restart recovery).
  /// One shot at a time; cancelled on success, disable, or dispose.
  void _scheduleRetry() {
    _retryTimer ??= Timer(const Duration(seconds: 2), () {
      _retryTimer = null;
      _sendConfig();
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _send(Map<String, dynamic> message) {
    final bridge = _bridge;
    if (bridge == null) {
      // Only the newest queued config matters; older ones are stale.
      if (message[LiveBridgeMessages.type] == LiveBridgeMessages.config) {
        _outbox.removeWhere(
          (m) => m[LiveBridgeMessages.type] == LiveBridgeMessages.config,
        );
      }
      if (message[LiveBridgeMessages.type] != LiveBridgeMessages.ping) {
        _outbox.removeWhere(
          (m) => m[LiveBridgeMessages.type] == message[LiveBridgeMessages.type],
        );
        _outbox.add(message);
      }
      return;
    }
    try {
      bridge.send(message);
    } catch (_) {}
  }

  void _sendConfig() {
    final config = ref.read(bridgeConfigProvider).value;
    if (config == null) return;
    _send({
      LiveBridgeMessages.type: LiveBridgeMessages.config,
      'enabled': config.enabled && ref.read(currentLaunchSiteProvider) != null,
      'port': config.port,
      'bind': config.bindAddress,
      'cors': config.corsOrigin,
    });
  }

  /// Whether [frame] may leave the app: live link, no replay in progress.
  bool _isLive() {
    if (ref.read(currentLaunchSiteProvider) == null) return false;
    if (ref.read(replayProvider).isActive) return false;
    return ref.read(serialStatusProvider).value?.isConnected ?? false;
  }

  void dispose() {
    mounted = false;
    _pingTimer?.cancel();
    _cancelRetry();
    _bridgeSub?.cancel();
    _fromBridge?.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _bridge = null;
    try {
      ref.read(bridgeStatusProvider.notifier).clear();
    } catch (_) {}
  }

  void listen() {
    ref.listen(currentLaunchSiteProvider, (_, _) => _sendConfig());
    ref.listen(bridgeConfigProvider, (_, next) {
      if (next.value?.enabled != true) _cancelRetry();
      _sendConfig();
    });

    ref.listen(telemetryStreamProvider, (_, next) {
      next.whenData((frame) {
        if (ref.read(bridgeConfigProvider).value?.enabled != true) return;
        if (!_isLive()) return;
        try {
          final siteMsl = ref.read(currentLaunchSiteProvider)?.altitudeMsl ?? 0;
          final sessionMaxAgl = ref.read(telemetryStoreProvider).maxAltitude;
          final hasParachute = ref
              .read(activeConnectorProvider)
              .stateForId(frame.fsmStateId)
              .hasParachute;
          _send({
            LiveBridgeMessages.type: LiveBridgeMessages.frame,
            'envelope': LiveBridgeSchema.packet(
              frame: frame,
              siteMslM: siteMsl,
              maxAltitudeAglM: math.max(sessionMaxAgl, frame.baroAltitude),
              hasParachute: hasParachute,
            ),
          });
        } catch (_) {}
      });
    });
  }
}
