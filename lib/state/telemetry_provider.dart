import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../foundation/store.dart';
import '../session/feedback.dart';
import './connector_provider.dart';
import './recording_provider.dart';
export './connector_provider.dart';
export './recording_provider.dart';

// ─── Core worker provider ──────────────────────────────────────────────────────

/// Holds the live [SerialWorker] handle.
///
/// Overridden in [main] with the instance spawned before [runApp].
final serialWorkerProvider = Provider<SerialWorker>((ref) {
  throw UnimplementedError(
    'serialWorkerProvider must be overridden in main() via ProviderScope.overrides.',
  );
});

// ─── Event-derived stream providers ───────────────────────────────────────────

/// Stream of [TelemetryFrame]s decoded by the worker's active connector.
///
/// Raw bytes never leave the serial package — the UI only deals in internal
/// frames. In tiles: `ref.watch(telemetryStreamProvider)`
///   → `AsyncValue<TelemetryFrame>` (loading / data / error)
final telemetryStreamProvider = StreamProvider<TelemetryFrame>((ref) {
  return ref.watch(serialWorkerProvider).frameStream;
});

/// Current serial worker status (connected, recording, active port, etc.).
///
/// Yields [SerialWorkerStatus] immediately with the latest cached value, then
/// streams every subsequent change.
final serialStatusProvider = StreamProvider<SerialWorkerStatus>((ref) async* {
  final worker = ref.watch(serialWorkerProvider);
  yield worker.currentStatus;
  yield* worker.statusStream;
});

/// Stream of cumulative link-health snapshots from the serial worker.
///
/// Emitted ~2 Hz while connected (plus throttled updates on traffic bursts).
/// The channel-health monitor derives bytes/s rates from counter deltas.
final linkStatsStreamProvider = StreamProvider<LinkStats>((ref) {
  final worker = ref.watch(serialWorkerProvider);
  return worker.linkStatsStream;
});

/// Most recently reported list of available serial ports.
///
/// Dev-gated: the MOCK / MOCK-BQ / Brno / MOCK-DC simulator ports only show in debug builds.
/// Release builds list physical ports alone (the worker still accepts a mock
/// name via `connect()` for tests, it just isn't offered in the picker).
final availablePortsProvider = StreamProvider<List<String>>((ref) async* {
  List<String> visible(List<String> ports) => kDebugMode
      ? ports
      : ports.where((p) => !SerialService.isMockPortName(p)).toList();
  final worker = ref.watch(serialWorkerProvider);
  yield visible(worker.currentPorts);
  await for (final ports in worker.portsStream) {
    yield visible(ports);
  }
});

/// Stream of uplink attempt reports from the serial worker (one per
/// handled [SendBytesCommand], sent or failed).
final commandEventsProvider = StreamProvider<CommandResultEvent>((ref) {
  final worker = ref.watch(serialWorkerProvider);
  return worker.commandStream;
});

/// Stream of worker-side errors (connect failures, unexpected disconnects,
/// failed transmits).
///
/// The worker used to only `print()` these, so failures were silent in the
/// UI. The serial toast bridge watches this and surfaces each message as a
/// toast; widgets that need one-shot error text can watch it directly.
final serialErrorsProvider = StreamProvider<ErrorEvent>((ref) {
  final worker = ref.watch(serialWorkerProvider);
  return worker.errorStream;
});

// ─── Live command log ────────────────────────────────────────────────────────

/// Operator uplink attempts this session (sent and failed), oldest first.
///
/// The worker reports every dispatched attempt via [commandEventsProvider];
/// attempts blocked before dispatch (not connected) are filed by
/// [SerialConfigNotifier.sendBytes] directly, so the log — and the
/// Commands tile reading it — sees *all* attempts. Bounded to the newest
/// [CommandLog.maxEntries] entries; the recording's command section is the
/// durable copy.
final commandLogProvider =
    NotifierProvider<CommandLog, List<SentCommand>>(CommandLog.new);

class CommandLog extends SessionStore<List<SentCommand>> {
  /// Ring cap for the in-memory log (the file keeps everything).
  static const int maxEntries = 2000;

  @override
  List<SentCommand> build() {
    // Worker-side outcomes (dispatched attempts, sent or failed).
    ref.listen(commandEventsProvider, (previous, next) {
      next.whenData((event) {
        add(
          SentCommand(
            tsUs: event.timestampMs * 1000,
            bytes: event.bytes,
            status: event.ok ? CommandStatus.sent : CommandStatus.failed,
            source: CommandSource.fromValue(event.source),
          ),
        );
      });
    });
    return const [];
  }

  /// Appends [command], dropping the oldest entries past [maxEntries].
  void add(SentCommand command) {
    final next = [...state, command];
    if (next.length > maxEntries) {
      next.removeRange(0, next.length - maxEntries);
    }
    state = next;
  }

  /// Clears the session log (new connection, test reset...).
  @override
  void clear() => state = const [];
}


// ─── UI-side connection config ─────────────────────────────────────────────────

/// Stores the selected port before the user clicks Connect.
class SerialConfig {
  final String? selectedPort;

  /// Port of the in-flight connect attempt, or `null` when idle.
  ///
  /// Set optimistically by [SerialConfigNotifier.connect] (the native open
  /// can block for a moment on cranky ports) and cleared when the worker
  /// answers — a connected status on success, any error on failure — or by
  /// a timeout fallback. [SerialControls] renders this as a "connecting"
  /// pill state so the click never looks dead.
  final String? connectingPort;

  /// Whether a port rescan is awaiting its fresh list.
  ///
  /// Set by [SerialConfigNotifier.refreshPorts]; [SerialToastBridge]
  /// consumes it to toast exactly one "Ports refreshed" acknowledgment per
  /// explicit rescan (startup scans stay silent).
  final bool refreshPending;

  const SerialConfig({this.selectedPort, this.connectingPort, this.refreshPending = false});

  static const _absent = Object();

  SerialConfig copyWith({
    Object? selectedPort = _absent,
    Object? connectingPort = _absent,
    bool? refreshPending,
  }) {
    return SerialConfig(
      selectedPort: identical(selectedPort, _absent)
          ? this.selectedPort
          : selectedPort as String?,
      connectingPort: identical(connectingPort, _absent)
          ? this.connectingPort
          : connectingPort as String?,
      refreshPending: refreshPending ?? this.refreshPending,
    );
  }
}

final serialConfigProvider =
    NotifierProvider<SerialConfigNotifier, SerialConfig>(
  SerialConfigNotifier.new,
);

/// Manages the pending serial config and dispatches commands to the worker.
class SerialConfigNotifier extends Notifier<SerialConfig> {
  /// Give up waiting for the worker this long after a connect attempt
  /// (success/failure normally answers in well under a second; a stuck
  /// isolate must not pin the pill on "connecting" forever).
  static const connectTimeout = Duration(seconds: 10);

  Timer? _connectTimer;

  @override
  SerialConfig build() {
    ref.onDispose(() {
      _connectTimer?.cancel();
      _connectTimer = null;
    });
    return const SerialConfig();
  }

  void setPort(String? port) {
    // The mock simulator ports are dev-only: ignore them in release builds
    // (the picker never offers them there).
    if (port != null && !kDebugMode && SerialService.isMockPortName(port)) {
      return;
    }
    state = state.copyWith(selectedPort: port);
  }

  /// Dispatches a [ConnectCommand] to the serial worker with the configured hardware settings.
  ///
  /// The active connector id rides along so the worker parses the
  /// bytestream with the connector the UI is showing. With no port picked
  /// this is a silent no-op: the link segment stays muted and inert until
  /// a port is selected, so the tap can never happen from the UI.
  /// attempt is marked optimistic ([SerialConfig.connectingPort]) — the
  /// native open can stall for a moment on cranky hardware — and cleared
  /// when the worker answers: [SerialControls] clears it on a connected
  /// status, [SerialToastBridge] on any error, or the timeout below (which
  /// toasts, so an attempt never dies silently).
  void connect() {
    final cfg = state;
    if (cfg.selectedPort == null) return;
    final port = cfg.selectedPort!;
    state = state.copyWith(connectingPort: port);
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      if (ref.mounted && state.connectingPort == port) {
        state = state.copyWith(connectingPort: null);
        // The worker never answered — a dead isolate drops commands
        // silently, so the pill unwinding is the only signal unless the
        // timeout says so itself.
        ref.errorToast(
          'Connecting to $port timed out — check the cable and retry.',
          title: 'Serial error',
        );
      }
    });
    final connectorId = ref.read(activeConnectorIdProvider).value ??
        defaultVisibleConnectorId;
    ref
        .read(serialWorkerProvider)
        .send(ConnectCommand(port, connectorId: connectorId));
  }

  /// Clears the in-flight connect mark (worker answered: connected status
  /// or error toast already surfaced). Idempotent; called from
  /// [SerialControls] and [SerialToastBridge], which own the worker
  /// subscriptions — `ref.listen` outside [build] does not reliably
  /// deliver stream events, so the notifier deliberately holds no
  /// subscriptions of its own.
  void clearConnecting() {
    if (state.connectingPort == null) return;
    _connectTimer?.cancel();
    state = state.copyWith(connectingPort: null);
  }

  /// Consumes the pending rescan acknowledgment after toasting it.
  void consumeRefresh() {
    if (!state.refreshPending) return;
    state = state.copyWith(refreshPending: false);
  }

  /// Selects the telemetry connector everywhere: persists the choice and
  /// tells the worker to re-parse with it. The telemetry store watches the
  /// connector id and clears the live flight itself (framings are
  /// connector-specific, so stale frames must go). Ignored while recording:
  /// a mid-recording switch would mix framings under one header stamp.
  Future<void> setConnector(String id) async {
    if (!isKnownConnectorId(id)) return;
    final recording =
        ref.read(serialStatusProvider).value?.isRecording ?? false;
    if (recording) return;
    await ref.read(activeConnectorIdProvider.notifier).set(id);
    final connected =
        ref.read(serialStatusProvider).value?.isConnected ?? false;
    if (connected) {
      ref.read(serialWorkerProvider).send(SetConnectorCommand(id));
    }
  }

  /// Dispatches a [DisconnectCommand] to the serial worker.
  void disconnect() {
    _connectTimer?.cancel();
    if (state.connectingPort != null) {
      state = state.copyWith(connectingPort: null);
    }
    ref.read(serialWorkerProvider).send(const DisconnectCommand());
  }

  /// Asks the worker to re-scan and push an updated port list.
  ///
  /// The fresh list is acknowledged with a "Ports refreshed" toast (see
  /// [SerialToastBridge]) — rescans previously gave no feedback at all.
  void refreshPorts() {
    state = state.copyWith(refreshPending: true);
    ref.read(serialWorkerProvider).send(const ListPortsCommand());
  }

  /// Starts a recording session with an auto-generated timestamp file in the documents recordings folder.
  Future<void> startRecording() => RecordingService.startRecording(ref);

  /// Stops the active recording session.
  void stopRecording() => RecordingService.stopRecording(ref);

  /// Transmits raw [bytes] to the rocket over the active connection.
  ///
  /// Used by the data-driven control panel and the FSM state chips;
  /// [source] files the attempt's origin in the command log. Returns
  /// whether the command was dispatched at all. Blocked attempts (not
  /// connected) are filed as failed immediately; dispatched attempts are
  /// filed by the worker's [CommandResultEvent] with their true outcome.
  bool sendBytes(
    List<int> bytes, {
    CommandSource source = CommandSource.unknown,
  }) {
    final status = ref.read(serialStatusProvider).value;
    if (status?.isConnected != true) {
      ref.read(commandLogProvider.notifier).add(SentCommand(
            tsUs: DateTime.now().microsecondsSinceEpoch,
            bytes: Uint8List.fromList(bytes),
            status: CommandStatus.failed,
            source: source,
          ));
      return false;
    }
    ref.read(serialWorkerProvider).send(
          SendBytesCommand(Uint8List.fromList(bytes), source: source.index),
        );
    return true;
  }

  /// Opens the recordings folder in the desktop OS file explorer.
  Future<void> openRecordingsFolder() => RecordingService.openRecordingsFolder();

  /// Resolves the user's `Documents/TryCatch/recordings` directory cross-platform.
  static Future<String> getRecordingsDirectory() =>
      RecordingService.getRecordingsDirectory();
}
