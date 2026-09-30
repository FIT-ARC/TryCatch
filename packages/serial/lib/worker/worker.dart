import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../serial.dart';

/// Pure lease check (unit-tested): `true` once [nowMs] is more than
/// [leaseMs] past the last command from the main isolate.
bool workerLeaseExpired({
  required int lastSignalMs,
  required int nowMs,
  int leaseMs = workerLeaseMs,
}) =>
    nowMs - lastSignalMs > leaseMs;

// ═══════════════════════════════════════════════════════════════════════════════
// workerMain: Entry Point (Runs in the BACKGROUND Isolate)
// ═══════════════════════════════════════════════════════════════════════════════

/// Entry point executed inside the dedicated background serial isolate.
///
/// Must be a top-level function so [Isolate.spawn] can locate and invoke it.
/// Runs a headless event loop responsible for:
/// 1. Native serial port I/O (via pure FFI libserialport).
/// 2. 1:1 raw binary disk dumping (via [Recorder]).
/// 3. Bytestream → internal-frame parsing via the selected [TelemetryConnector].
///
/// Liveness: child isolates survive a hot restart, so the worker releases
/// its link once its main isolate stops proving it is alive (see
/// [workerLeaseMs] and [PingCommand]) and exits after prolonged silence
/// (see [workerOrphanExitMs]) — otherwise the orphan would squat on the
/// serial port forever. The two stages matter: sleep freezes timers exactly
/// like death, so a merely-sleeping app must find its worker alive on wake.
void workerMain(SendPort mainSendPort) async {
  // ── Handshake Step 1 ─────────────────────────────────────────────────────────
  // Create an inbox for receiving commands from the main UI isolate
  final commandPort = ReceivePort();

  // Send our command SendPort (thread channel) back to the main UI isolate
  mainSendPort.send(commandPort.sendPort);

  // Initialize isolate-local services
  final service = SerialService();
  var connector = connectorById(defaultConnectorId) ?? mockConnector;
  var parser = connector.createParser();
  final recorder = Recorder();

  var status = SerialWorkerStatus(connectorId: connector.id);
  StreamSubscription<Uint8List>? byteSubscription;
  Timer? statsTimer;
  int lastStatsEmitMs = 0;

  /// Last command (any type, pings included) from the main isolate.
  ///
  /// The 500 ms stats tick enforces the lease (see [workerLeaseMs] and
  /// [workerOrphanExitMs]): once the main isolate is gone — hot restart —
  /// no command ever arrives again and the worker first drops the link,
  /// then shuts itself down, instead of squatting on the port. Starts at
  /// boot so a main that dies before its first command still releases
  /// everything.
  int lastSignalMs = DateTime.now().millisecondsSinceEpoch;

  /// Full teardown: release ports, finalize any recording, close the inbox.
  ///
  /// With no live ports, timers, or subscriptions left, the isolate exits
  /// on its own afterwards.
  Future<void> shutdown() async {
    await byteSubscription?.cancel();
    byteSubscription = null;
    statsTimer?.cancel();
    statsTimer = null;
    service.disconnect();
    try {
      await recorder.stop();
    } catch (_) {}
    commandPort.close();
  }

  /// Updates local status and notifies the main UI isolate
  void pushStatus(SerialWorkerStatus next) {
    status = next;
    mainSendPort.send(StatusChangedEvent(next));
  }

  LinkStats snapshotStats() => LinkStats(
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        totalBytes: parser.totalBytes,
        matchedBytes: parser.matchedBytes,
        garbageBytes: parser.garbageBytes,
        crcErrorBytes: parser.crcErrorBytes,
        matchedPackets: parser.matchedPackets,
        crcErrors: parser.crcErrorCount,
      );

  LinkStats? lastEmitted;

  bool sameCounters(LinkStats? a, LinkStats b) {
    if (a == null) return false;
    return a.totalBytes == b.totalBytes &&
        a.matchedBytes == b.matchedBytes &&
        a.garbageBytes == b.garbageBytes &&
        a.crcErrorBytes == b.crcErrorBytes &&
        a.matchedPackets == b.matchedPackets &&
        a.crcErrors == b.crcErrors;
  }

  void emitStats({bool force = false, bool onlyIfChanged = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - lastStatsEmitMs < 250) return;
    final snap = snapshotStats();
    if (onlyIfChanged && sameCounters(lastEmitted, snap)) {
      // Silence, not news: emitting zero-delta heartbeats would refresh the
      // UI's latest sample with a 0.0 rate (masking link-loss aging) and
      // spike it on resume (whole-outage delta over one heartbeat). The UI
      // derives staleness from snapshot age instead.
      return;
    }
    lastStatsEmitMs = now;
    lastEmitted = snap;
    mainSendPort.send(LinkStatsEvent(snap));
  }

  /// Switches the active connector, recreating the stream parser.
  ///
  /// Unknown ids fall back to the default connector. The status update
  /// notifies the UI so it can re-resolve states/commands/capabilities.
  void useConnector(String connectorId) {
    connector = connectorById(connectorId) ?? mockConnector;
    parser = connector.createParser();
    lastStatsEmitMs = 0;
    pushStatus(status.copyWith(connectorId: connector.id));
  }

  /// Central teardown for every unexpected link loss path (stream error,
  /// stream done, watchdog, failed transmit on a dead handle).
  ///
  /// Cancels the byte forwarder, drops the native handle, resets framing
  /// state, flips the UI status to disconnected (so the port picker
  /// unlocks) and surfaces one [ErrorEvent] for the toast bridge.
  void markDisconnected(String reason) {
    byteSubscription?.cancel();
    byteSubscription = null;
    service.disconnect();
    parser.reset();
    // Only notify when the UI still thinks we are up: user-initiated
    // disconnects already pushed their own status update.
    if (status.isConnected) {
      final lostPort = status.connectedPort;
      pushStatus(status.copyWith(isConnected: false, connectedPort: null));
      // Port named exactly once: callers pass a bare reason, and reasons
      // that already name it (native errors) are sent as-is.
      final message = lostPort == null || reason.contains(lostPort)
          ? reason
          : '$reason — $lostPort';
      mainSendPort.send(ErrorEvent(message));
      emitStats(force: true);
    }
  }

  /// Steady heartbeat so the UI graph decays to zero during silence and
  /// keeps a regular sample cadence (not just on chunk arrival).
  ///
  /// Doubles as a disconnect watchdog: [RealSerialPort] swallows native
  /// handle loss internally (its broadcast byte controller never errors or
  /// closes), so a yanked USB adapter would otherwise leave [status] stuck
  /// at "connected" with no packets and no error — the half-open state.
  /// Every tick reconciles [status] against [SerialService.isConnected].
  void ensureStatsTimer() {
    statsTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) async {
      // Liveness lease, stage one: no word from main within [workerLeaseMs].
      // OS sleep freezes timers while the wall clock advances, so this is
      // indistinguishable from a dead main isolate (hot restart) — release
      // the link but stay alive to serve commands. A merely-sleeping app
      // renews the lease with its next ping and reconnects cleanly; a true
      // orphan holds no port from here on. Deliberately error-free: there is
      // nobody to hear it when the main is really dead, and a wake is not
      // a failure worth toasting about.
      if (workerLeaseExpired(
        lastSignalMs: lastSignalMs,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      )) {
        if (status.isConnected) {
          byteSubscription?.cancel();
          byteSubscription = null;
          service.disconnect();
          parser.reset();
          pushStatus(status.copyWith(isConnected: false, connectedPort: null));
          emitStats(force: true);
        }
        // Stage two: minutes of continued silence means the main isolate is
        // really gone — exit instead of idling forever.
        if (workerLeaseExpired(
          lastSignalMs: lastSignalMs,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          leaseMs: workerOrphanExitMs,
        )) {
          await shutdown();
        }
        return;
      }
      if (status.isConnected && !service.isConnected) {
        markDisconnected('Port disconnected');
        return;
      }
      if (status.isConnected) emitStats(force: true, onlyIfChanged: true);
    });
  }

  /// Port enumeration never throws past this point: on some Linux/macOS
  /// setups `SerialPort.availablePorts` throws (permissions, missing udev,
  /// driver quirks) which used to kill the whole worker isolate.
  List<String> safePorts() {
    try {
      return SerialService.availablePorts;
    } catch (e) {
      mainSendPort.send(ErrorEvent('Port scan failed: $e'));
      return const [];
    }
  }

  /// Subscribes to the serial byte stream and processes chunks concurrently
  void attachByteStream() {
    byteSubscription?.cancel();
    byteSubscription = service.byteStream.listen(
      (chunk) {
        // 1. Exact 1:1 raw binary disk recording (includes noise, preamble, fragments)
        recorder.recordBytes(chunk);

        // 2. Decode valid telemetry frames and forward them to the UI isolate
        for (final frame in parser.feed(chunk)) {
          mainSendPort.send(PacketReceivedEvent(frame));
        }
        // 3. Fresh channel-health snapshot (throttled).
        emitStats();
      },
      onError: (Object e) {
        markDisconnected('Port error: $e');
      },
      onDone: () {
        // Previously silent: the UI kept showing "connected" with a dead
        // stream. Treat any unexpected close as a disconnect.
        markDisconnected('Port closed');
      },
      cancelOnError: true,
    );
    ensureStatsTimer();
  }

  // The lease + watchdog tick runs from boot (not just while connected):
  // a worker whose main died before its first connect must still exit.
  ensureStatsTimer();

  // Push initial hardware port discovery list upon startup
  mainSendPort.send(PortListEvent(safePorts()));

  // ── Command Loop ─────────────────────────────────────────────────────────────
  // Dart's event loop handles this command loop and the serial byte stream
  // concurrently without thread contention or manual mutex locking.
  await for (final message in commandPort) {
    if (message is! SerialCommand) continue;
    // Any command proves the main isolate is alive — renew the lease.
    lastSignalMs = DateTime.now().millisecondsSinceEpoch;

    switch (message) {
      case ConnectCommand(:final port, :final connectorId):
        byteSubscription?.cancel();
        byteSubscription = null;
        service.disconnect();
        useConnector(connectorId);

        // Connect using centralized SerialHardwareConfig settings.
        // service.connect() returns false on failure but native FFI calls
        // can also throw per-platform (permissions on Linux/macOS,
        // missing driver on Windows) — either way the UI must hear about
        // it instead of sitting on a dead picker.
        bool ok = false;
        String? failure;
        try {
          ok = service.connect(port);
        } catch (e) {
          ok = false;
          failure = e.toString();
        }

        if (ok) {
          pushStatus(status.copyWith(isConnected: true, connectedPort: port));
          lastStatsEmitMs = 0;
          attachByteStream();
          emitStats(force: true);
        } else {
          pushStatus(status.copyWith(isConnected: false, connectedPort: null));
          // Port named exactly once: native failures may already name it.
          const hint =
              'check the cable, driver and that no other app holds the port';
          mainSendPort.send(ErrorEvent(
            failure == null
                ? 'Failed to open $port — $hint'
                : failure.contains(port)
                    ? '$failure — $hint'
                    : 'Failed to open $port — $failure',
          ));
        }

      case DisconnectCommand():
        byteSubscription?.cancel();
        byteSubscription = null;
        service.disconnect();
        parser.resetStats();
        pushStatus(status.copyWith(isConnected: false, connectedPort: null));
        emitStats(force: true);

      case PingCommand():
        // Heartbeat (see [workerLeaseMs]): the lease was already renewed
        // above; nothing else to do — deliberately ack-free.
        break;

      case SetConnectorCommand(:final connectorId):
        useConnector(connectorId);
        emitStats(force: true);

      case ListPortsCommand():
        mainSendPort.send(PortListEvent(safePorts()));

      case SendBytesCommand(:final bytes, :final source):
        final ok = service.sendBytes(bytes);
        final now = DateTime.now();
        // File every attempt (sent or failed) in the recording's command
        // section and report it to the UI for the live command log.
        recorder.recordCommand(SentCommand(
          tsUs: now.microsecondsSinceEpoch,
          bytes: Uint8List.fromList(bytes),
          status:
              ok ? CommandStatus.sent : CommandStatus.failed,
          source: CommandSource.fromValue(source),
        ));
        mainSendPort.send(CommandResultEvent(
          bytes: Uint8List.fromList(bytes),
          timestampMs: now.millisecondsSinceEpoch,
          ok: ok,
          source: source,
        ));
        if (!ok) {
          // A failed transmit on a dead handle means the link is gone even
          // when packets were still arriving a moment ago (TX stall on a
          // floating CTS, unplugged adapter, suspended USB). Flip the status
          // so the UI unlocks the picker instead of staying half-open.
          if (status.isConnected && !service.isConnected) {
            final lostPort = status.connectedPort;
            pushStatus(
                status.copyWith(isConnected: false, connectedPort: null));
            parser.reset();
            byteSubscription?.cancel();
            byteSubscription = null;
            mainSendPort.send(ErrorEvent(
              'Port disconnected — failed to send ${bytes.length} byte(s)'
              '${lostPort == null ? '' : ' ($lostPort)'}',
            ));
            emitStats(force: true);
          } else {
            mainSendPort.send(ErrorEvent(
              status.isConnected
                  ? 'Send failed (${bytes.length} byte(s)) — link may be down, try reconnecting'
                  : 'Not connected — failed to send ${bytes.length} byte(s)',
            ));
          }
        }

      case StartRecordingCommand(
            :final filePath,
            :final launch,
            :final connectorId
          ):
        await recorder.start(
          filePath,
          launch: launch,
          connectorId: connectorId,
        );
        pushStatus(status.copyWith(isRecording: true, recordingPath: filePath));

      case StopRecordingCommand():
        await recorder.stop();
        pushStatus(status.copyWith(isRecording: false, recordingPath: null));
    }
  }
}
