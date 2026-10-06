import 'dart:async';
import 'dart:isolate';

import '../serial.dart';
import 'worker.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// SerialWorker: Client Handle (Runs in the MAIN / UI Isolate)
// ═══════════════════════════════════════════════════════════════════════════════

/// A high-level controller and client handle that lives in the main UI isolate.
///
/// Analogous to a Web Worker instance in JavaScript or a thread manager in C:
/// - Sends typed [SerialCommand]s to the background worker isolate.
/// - Exposes categorized broadcast [Stream]s for UI widgets to consume.
///
/// In Dart, isolates do NOT share memory heaps. All communication is done via
/// message passing over [SendPort] and [ReceivePort].
class SerialWorker {
  final Isolate _isolate;
  final ReceivePort _inbox;
  final ReceivePort _lifecycle;
  late final StreamSubscription<dynamic> _inboxSubscription;
  late final StreamSubscription<dynamic> _lifecycleSubscription;
  bool _disposed = false;
  bool _failed = false;
  bool _shuttingDown = false;
  final _shutdown = Completer<void>();
  Future<void>? _shutdownFuture;

  /// The communication pipe endpoint (SendPort) to send commands to the background worker.
  /// Initialized during the two-way handshake upon isolate startup.
  SendPort? _commandPort;

  /// Completes when the isolate handshake finishes ([ready]). Commands sent
  /// before that are held in [_outbox] and flushed in order — a connect tap
  /// in the first milliseconds must not vanish silently (release builds
  /// skip asserts, so the old `_commandPort?.send` dropped it without a
  /// trace).
  final _readyCompleter = Completer<void>();
  final _outbox = <SerialCommand>[];

  // Broadcast stream controllers: allow multiple UI widgets to listen simultaneously
  final _statusController = StreamController<SerialWorkerStatus>.broadcast();
  final _frameController = StreamController<TelemetryFrame>.broadcast();
  final _portsController = StreamController<List<String>>.broadcast();
  final _linkStatsController = StreamController<LinkStats>.broadcast();
  final _commandController = StreamController<CommandResultEvent>.broadcast();
  final _errorController = StreamController<ErrorEvent>.broadcast();

  // Cached state snapshots: allow UI widgets to perform immediate synchronous reads
  // without waiting for the next stream event (avoids UI loading flashes).
  SerialWorkerStatus _status = const SerialWorkerStatus();
  List<String> _ports = const [];
  LinkStats _linkStats = LinkStats.empty;

  /// Current synchronous snapshot of the worker's operational status.
  SerialWorkerStatus get currentStatus => _status;

  /// Current synchronous snapshot of available COM / serial ports.
  List<String> get currentPorts => _ports;

  /// Stream of connection and recording status transitions.
  Stream<SerialWorkerStatus> get statusStream => _statusController.stream;

  /// Stream of [TelemetryFrame]s decoded by the active connector.
  ///
  /// Raw bytes never leave the worker — the UI only deals in internal frames.
  Stream<TelemetryFrame> get frameStream => _frameController.stream;

  /// Stream of scanned serial/COM port list updates.
  Stream<List<String>> get portsStream => _portsController.stream;

  /// Latest cumulative link-health snapshot from the worker.
  LinkStats get currentLinkStats => _linkStats;

  /// Stream of cumulative [LinkStats] snapshots (~2 Hz while connected).
  Stream<LinkStats> get linkStatsStream => _linkStatsController.stream;

  /// Stream of uplink attempt reports (one per handled [SendBytesCommand]).
  Stream<CommandResultEvent> get commandStream => _commandController.stream;

  /// Stream of worker-side errors (connect failures, port loss, send
  /// failures). Previously these were only `print()`ed in the UI isolate
  /// and never surfaced — the UI now toasts them (see `serialErrorsProvider`).
  Stream<ErrorEvent> get errorStream => _errorController.stream;

  /// Completes once the background isolate finishes its startup handshake
  /// and is ready to receive commands. Await before time-sensitive sends
  /// in tests; the app itself doesn't need it ([send] buffers early
  /// commands in [_outbox]).
  Future<void> get ready => _readyCompleter.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => throw StateError('Serial worker did not start.'),
  );

  SerialWorker._(this._isolate, this._inbox, this._lifecycle) {
    _readyCompleter.future.ignore();
    _inboxSubscription = _inbox.listen(_handleMessage);
    _lifecycleSubscription = _lifecycle.listen((message) {
      if (_disposed ||
          _failed ||
          _shutdown.isCompleted ||
          (_shuttingDown && message == null)) {
        return;
      }
      _failed = true;
      _commandPort = null;
      final failure = StateError(
        'Serial worker stopped before completing its work.',
      );
      if (!_readyCompleter.isCompleted) _readyCompleter.completeError(failure);
      if (_shuttingDown && !_shutdown.isCompleted) {
        _shutdown.completeError(failure);
      }
      _status = _status.copyWith(
        isConnected: false,
        connectedPort: null,
        isRecording: false,
        recordingPath: null,
      );
      _statusController.add(_status);
      _errorController.add(
        ErrorEvent(
          'Serial worker stopped${message is List ? ': ${message.first}' : ''} — restart the app',
        ),
      );
      _outbox.clear();
    });
  }

  /// Handles incoming messages received from the background worker isolate.
  void _handleMessage(dynamic message) {
    // ── Handshake Step 2 ───────────────────────────────────────────────────────
    // The very first message sent by the worker is its own command SendPort
    // (a thread communication channel, NOT a hardware COM port).
    if (message is SendPort) {
      _commandPort = message;
      for (final pending in _outbox) {
        _commandPort!.send(pending);
      }
      _outbox.clear();
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
      // Immediately request an initial scan of available hardware ports
      _commandPort!.send(const ListPortsCommand());
      return;
    }

    if (message is! SerialEvent) return;

    // ── Event Dispatching ─────────────────────────────────────────────────────
    // Route domain events to their respective broadcast stream controllers.
    // Every add is close-guarded: late isolate messages racing [dispose]
    // (app shutdown, hot restart, test teardown) must not throw.
    switch (message) {
      case ShutdownCompleteEvent(:final error):
        if (!_shutdown.isCompleted) {
          if (error == null) {
            _shutdown.complete();
          } else {
            _shutdown.completeError(StateError(error));
          }
        }
      case PacketReceivedEvent(:final frame):
        if (!_frameController.isClosed) _frameController.add(frame);

      case StatusChangedEvent(:final status):
        _status = status;
        if (!_statusController.isClosed) _statusController.add(status);

      case PortListEvent(:final ports):
        // Note: PortListEvent contains hardware COM port names (e.g. 'COM3', 'MOCK')
        _ports = ports;
        if (!_portsController.isClosed) _portsController.add(ports);

      case LinkStatsEvent(:final stats):
        _linkStats = stats;
        if (!_linkStatsController.isClosed) _linkStatsController.add(stats);

      case final ErrorEvent errorEvent:
        if (!_errorController.isClosed) _errorController.add(errorEvent);

      case final CommandResultEvent commandEvent:
        if (!_commandController.isClosed) _commandController.add(commandEvent);
    }
  }

  /// Spawns the dedicated serial background isolate.
  ///
  /// This creates a new OS thread running an isolated Dart heap.
  /// Call this once during app initialization in [main] before [runApp].
  static Future<SerialWorker> spawn() async {
    // Create an inbox (ReceivePort) for the main isolate
    final receivePort = ReceivePort();
    final lifecycle = ReceivePort();

    // Spawn the background thread and pass our SendPort so it can talk back
    try {
      final isolate = await Isolate.spawn(
        workerMain,
        receivePort.sendPort,
        debugName: 'SerialWorker',
        onError: lifecycle.sendPort,
        onExit: lifecycle.sendPort,
      );
      return SerialWorker._(isolate, receivePort, lifecycle);
    } catch (_) {
      receivePort.close();
      lifecycle.close();
      rethrow;
    }
  }

  /// Posts a [SerialCommand] to the background worker isolate.
  ///
  /// The command object is serialized/copied across the isolate boundary.
  /// Safe to call before the startup handshake finishes: early commands
  /// wait in an outbox and flush in order once the command port arrives.
  void send(SerialCommand command) {
    if (_disposed || _failed) return;
    final port = _commandPort;
    if (port == null) {
      _outbox.add(command);
      return;
    }
    port.send(command);
  }

  /// Flushes the recording before releasing worker resources.
  Future<void> shutdown() => _shutdownFuture ??= _shutdownGracefully();

  Future<void> _shutdownGracefully() async {
    if (_disposed) return;
    try {
      if (_failed) throw StateError('Serial worker is unavailable.');
      await ready;
      _shuttingDown = true;
      send(const ShutdownCommand());
      await _shutdown.future.timeout(const Duration(seconds: 15));
    } finally {
      dispose();
    }
  }

  /// Emergency teardown. Normal app exit uses [shutdown] to flush recording.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _outbox.clear();
    _inboxSubscription.cancel();
    _lifecycleSubscription.cancel();
    _inbox.close();
    _lifecycle.close();
    _statusController.close();
    _frameController.close();
    _portsController.close();
    _linkStatsController.close();
    _commandController.close();
    _errorController.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}
