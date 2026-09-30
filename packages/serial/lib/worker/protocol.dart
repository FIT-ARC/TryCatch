import 'dart:typed_data';

import '../constants.dart';
import '../telemetry/telemetry_frame.dart';

// ─── Commands (UI → Serial Worker Isolate) ───────────────────────────────────

/// Liveness lease for the worker isolate, in milliseconds.
///
/// The worker holds OS-exclusive resources yet child isolates survive a hot
/// restart — so it releases its link once its main isolate stops proving it
/// is alive (every received command, [PingCommand] included, renews the
/// lease; see [workerLeaseExpired]). The app pings every 2 s, giving a
/// zombie at most an 8 s squat on the port before the user can reconnect
/// cleanly.
///
/// Sleep looks exactly like death here (timers freeze while the wall clock
/// advances), so expiry only releases the link — the isolate keeps serving
/// commands, and the first post-wake ping renews the lease. A main isolate
/// that never comes back is reaped by [workerOrphanExitMs].
const int workerLeaseMs = 8000;

/// Grace period of continued silence before a link-less worker isolate
/// exits.
///
/// Stage two of the liveness lease: minutes without a single command means
/// the main isolate is really gone (hot restart), so the orphan shuts down
/// instead of idling forever. A merely-sleeping app pings within seconds of
/// waking — far inside this window — so it always finds its worker alive.
const int workerOrphanExitMs = 60000;

/// Pure lease check (unit-tested): `true` once [nowMs] is more than
/// [leaseMs] past the last command from the main isolate.
bool workerLeaseExpired({
  required int lastSignalMs,
  required int nowMs,
  int leaseMs = workerLeaseMs,
}) =>
    nowMs - lastSignalMs > leaseMs;

/// Base class for all commands sent to the serial worker isolate.
sealed class SerialCommand {
  const SerialCommand();
}

/// Open a serial port using centralized hardware settings from [SerialHardwareConfig].
///
/// [connectorId] selects the telemetry connector used to parse the
/// bytestream into internal [TelemetryFrame]s (see `connectors/registry.dart`).
class ConnectCommand extends SerialCommand {
  final String port;

  /// Stable connector id (defaults to the MOCK connector).
  final String connectorId;

  const ConnectCommand(this.port, {this.connectorId = 'mock'});
}

/// Switch the active telemetry connector without touching the connection.
///
/// The worker recreates its stream parser, so byte counters restart.
class SetConnectorCommand extends SerialCommand {
  /// Stable connector id (unknown ids fall back to the default connector).
  final String connectorId;

  const SetConnectorCommand(this.connectorId);
}

/// Close the active serial port connection.
class DisconnectCommand extends SerialCommand {
  const DisconnectCommand();
}

/// Heartbeat proving the main isolate is still alive.
///
/// The worker holds OS-exclusive resources (serial handles, recording
/// files) and child isolates survive a hot restart — without a pulse the
/// previous incarnation's worker would squat on the port forever. Every
/// received command (this one included) renews the lease (see
/// [workerLeaseMs]); workers must be pinged periodically, and the app does
/// so from [main]. Deliberately ack-free: no UI churn.
class PingCommand extends SerialCommand {
  const PingCommand();
}

/// Request a scan of available COM ports and simulated ports.
class ListPortsCommand extends SerialCommand {
  const ListPortsCommand();
}

/// Transmit raw [bytes] to the rocket over the active connection.
///
/// Used by the control panel for arming / deployment commands defined entirely
/// on the UI side as data. [source] is the [CommandSource] wire value
/// (see `telemetry/sent_command.dart`) so the worker can file the attempt
/// in the recording's command log with its origin.
class SendBytesCommand extends SerialCommand {
  final Uint8List bytes;

  /// Origin of the attempt, as a [CommandSource] index (0 = unknown).
  final int source;

  const SendBytesCommand(this.bytes, {this.source = 0});
}

/// Start recording the raw bytestream to the given file path.
class StartRecordingCommand extends SerialCommand {
  final String filePath;

  /// Launch site stamped into the recording file header. Required — every
  /// recording carries its site (a site must be selected before recording).
  final LaunchRef launch;

  /// Stable connector id stamped into the recording header so playback can
  /// auto-select the connector the file was recorded with.
  final String connectorId;

  const StartRecordingCommand({
    required this.filePath,
    required this.launch,
    this.connectorId = 'mock',
  });
}

/// Stop the current recording session and flush to disk.
class StopRecordingCommand extends SerialCommand {
  const StopRecordingCommand();
}

// ─── Events (Serial Worker Isolate → UI) ─────────────────────────────────────

/// Base class for all events emitted from the serial worker isolate.
sealed class SerialEvent {}

/// Emitted whenever the active connector decodes a [TelemetryFrame] from
/// the bytestream. Raw bytes never leave the worker — the UI only deals in
/// internal frames.
class PacketReceivedEvent extends SerialEvent {
  final TelemetryFrame frame;
  PacketReceivedEvent(this.frame);
}

/// Cumulative byte counters describing what the parser saw on the wire.
///
/// `matchedBytes` (ours) decoded into our packets; `garbageBytes` never contained
/// a sync word and `crcErrorBytes` framed but failed CRC — together they are
/// unknown traffic on our frequency (not ours: unknown transmitters, noise).
/// Counters reset on every (re)connect; the UI derives bytes/s from deltas.
class LinkStats {
  final int timestampMs;
  final int totalBytes;
  final int matchedBytes;
  final int garbageBytes;
  final int crcErrorBytes;
  final int matchedPackets;
  final int crcErrors;

  const LinkStats({
    required this.timestampMs,
    this.totalBytes = 0,
    this.matchedBytes = 0,
    this.garbageBytes = 0,
    this.crcErrorBytes = 0,
    this.matchedPackets = 0,
    this.crcErrors = 0,
  });

  /// Bytes that arrived but never became one of our packets (unknown).
  int get unmatchedBytes => garbageBytes + crcErrorBytes;

  static const empty = LinkStats(timestampMs: 0);
}

/// Emitted (throttled, ~2 Hz plus on every stats change burst) with the
/// latest cumulative [LinkStats] snapshot from the worker isolate.
class LinkStatsEvent extends SerialEvent {
  final LinkStats stats;
  LinkStatsEvent(this.stats);
}

/// Emitted with the list of detected serial ports.
class PortListEvent extends SerialEvent {
  final List<String> ports;
  PortListEvent(this.ports);
}

/// Emitted when connection status or recording state changes.
class StatusChangedEvent extends SerialEvent {
  final SerialWorkerStatus status;
  StatusChangedEvent(this.status);
}

/// Emitted when a serial or parsing error occurs.
///
/// [timestampMs] lets the UI order and dedupe rapid bursts; defaults to
/// "now" so existing call sites (`ErrorEvent('...')`) keep compiling.
class ErrorEvent extends SerialEvent {
  final String message;
  final int timestampMs;

  ErrorEvent(this.message, [int? timestampMs])
      : timestampMs = timestampMs ??
            DateTime.now().millisecondsSinceEpoch;
}

/// Emitted for every uplink attempt handled by the worker (one per
/// [SendBytesCommand]): the exact [bytes], the worker-side [timestampMs]
/// and whether the transmit succeeded. The UI appends these to the live
/// command log; the worker additionally files them in the active
/// recording's command section.
class CommandResultEvent extends SerialEvent {
  final Uint8List bytes;
  final int timestampMs;
  final bool ok;

  /// Origin of the attempt, as a [CommandSource] index (0 = unknown).
  final int source;

  CommandResultEvent({
    required this.bytes,
    required this.timestampMs,
    required this.ok,
    this.source = 0,
  });
}

// ─── Data Models ─────────────────────────────────────────────────────────────

/// Launch-site reference stamped into a recording file header.
///
/// Plain doubles + String so the command stays isolate-transferable.
/// Defined here (rather than next to the file format) to keep the worker
/// protocol dependency-free.
class LaunchRef {
  /// WGS84 latitude in degrees (positive North).
  final double latitude;

  /// WGS84 longitude in degrees (positive East).
  final double longitude;

  /// Site altitude above mean sea level in metres.
  final double mslM;

  /// Display name (truncated to fit the fixed header on write).
  final String name;

  const LaunchRef({
    required this.latitude,
    required this.longitude,
    required this.mslM,
    this.name = '',
  });
}

/// Immutable snapshot of the serial worker's operational state.
class SerialWorkerStatus {
  final bool isConnected;
  final String? connectedPort;
  final bool isRecording;
  final String? recordingPath;

  /// Stable id of the connector currently parsing the bytestream.
  final String connectorId;

  const SerialWorkerStatus({
    this.isConnected = false,
    this.connectedPort,
    this.isRecording = false,
    this.recordingPath,
    this.connectorId = 'mock',
  });

  static const _absent = Object();

  SerialWorkerStatus copyWith({
    bool? isConnected,
    Object? connectedPort = _absent,
    bool? isRecording,
    Object? recordingPath = _absent,
    String? connectorId,
  }) {
    return SerialWorkerStatus(
      isConnected: isConnected ?? this.isConnected,
      connectedPort: identical(connectedPort, _absent)
          ? this.connectedPort
          : connectedPort as String?,
      isRecording: isRecording ?? this.isRecording,
      recordingPath: identical(recordingPath, _absent)
          ? this.recordingPath
          : recordingPath as String?,
      connectorId: connectorId ?? this.connectorId,
    );
  }
}

/// A parsed telemetry frame consisting of a timestamp and raw payload bytes.
class TelemetryPacket {
  /// Milliseconds since Unix epoch when packet was parsed.
  final int receivedAtMs;

  /// The raw payload bytes (excluding the start word header).
  final Uint8List rawData;

  const TelemetryPacket({required this.receivedAtMs, required this.rawData});
}
