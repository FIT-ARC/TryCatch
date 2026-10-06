import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../telemetry/sent_command.dart';
import '../worker/protocol.dart';
import 'recording_file.dart';

/// Handles recording raw binary byte streams directly to disk with framing headers.
///
/// Records every raw byte received over the serial interface (including preamble
/// noise, fragmented frames, and corrupted bytes) prepended with a 12-byte framing header
/// (64-bit microsecond timestamp + 32-bit payload length) for complete diagnostic fidelity.
///
/// Every file opens with a fixed v3 [RecordingHeader]: [start] writes a
/// provisional one carrying the launch site + connector id (stats filled
/// in on [stop]), and [stop] replaces it with the computed stats via
/// [finalizeRecordingFile]. The finalize pass never throws: on any failure
/// the provisional header is left untouched. Files without the magic are
/// rejected by every reader.
///
/// Operator uplink attempts buffered via [recordCommand] are appended as
/// the file's trailing command section on [stop] (the live telemetry
/// stream cannot be interleaved with a trailing section, so commands are
/// held in memory for the session — a crash loses buffered commands but
/// never telemetry).
class Recorder {
  /// Reports asynchronous write failures without terminating serial ingestion.
  void Function(Object error)? onError;
  IOSink? _sink;
  String? _filePath;
  LaunchRef? _launch;
  String _connectorId = 'mock';
  int _bytesWritten = 0;
  int _chunksWritten = 0;
  final List<SentCommand> _commands = [];

  /// Whether a recording session is currently active.
  bool get isRecording => _sink != null;

  /// File path of the active recording session, or `null` if inactive.
  String? get filePath => _filePath;

  /// Total number of chunk bytes recorded in the current session
  /// (12-byte framing + payload per chunk — excludes the file header).
  int get bytesWritten => _bytesWritten;

  /// Starts a recording session targeting [filePath].
  ///
  /// [launch] stamps the launch site into the file header — required, so
  /// even a crash-interrupted file carries its site (stats are filled in
  /// on [stop]). [connectorId] stamps the connector the bytestream belongs
  /// to so playback can auto-select it.
  /// Automatically creates parent directories if they don't exist and opens
  /// an unbuffered asynchronous write stream. A provisional header is
  /// written first so the file is a valid recording from the start.
  Future<void> start(
    String filePath, {
    required LaunchRef launch,
    required String connectorId,
  }) async {
    await stop();

    final file = File(filePath);
    await file.parent.create(recursive: true);
    await file.create(exclusive: true);

    final sink = _sink = file.openWrite();
    sink.done.then(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (identical(_sink, sink)) onError?.call(error);
      },
    );
    _filePath = filePath;
    _launch = launch;
    _connectorId = connectorId;
    _bytesWritten = 0;
    _chunksWritten = 0;
    _commands.clear();
    _sink!.add(
      RecordingHeader(
        payloadLength: TelemetryFraming.payloadLength,
        hasLaunchSite: true,
        launchLatitude: launch.latitude,
        launchLongitude: launch.longitude,
        launchMslM: launch.mslM,
        launchName: launch.name,
        connectorId: connectorId,
      ).encode(),
    );
    try {
      await sink.flush();
    } catch (_) {
      try {
        await stop();
      } catch (_) {}
      rethrow;
    }
  }

  /// Stops the active recording session, flushes all buffered bytes to disk,
  /// replaces the provisional header with the computed stats, appends the
  /// buffered command log, and closes the underlying file handle.
  Future<void> stop() async {
    if (_sink != null) {
      final sink = _sink;
      final path = _filePath;
      final launch = _launch;
      final connectorId = _connectorId;
      final chunks = _chunksWritten;
      final commands = List<SentCommand>.unmodifiable(_commands);
      _sink = null;
      _filePath = null;
      _launch = null;
      _connectorId = 'mock';
      _chunksWritten = 0;
      _commands.clear();
      try {
        await sink?.flush();
      } finally {
        await sink?.close();
      }
      // Finalize telemetry stats and commands after the stream is closed.
      // Sessions without radio chunks produce an empty file.
      if (path != null) {
        if (chunks > 0 && launch != null) {
          final header = await finalizeRecordingFile(
            path,
            launch: launch,
            connectorId: connectorId,
            commands: commands,
            throwOnError: true,
          );
          if (header == null) {
            throw FileSystemException('Could not finalize recording', path);
          }
        } else {
          await File(path).writeAsBytes(const []);
        }
      }
    }
  }

  /// Appends raw [bytes] to the recording file prepended with a 12-byte timestamp frame header.
  ///
  /// Non-blocking O(1) write operation handled by Dart's asynchronous I/O loop.
  void recordBytes(Uint8List bytes) {
    if (_sink == null || bytes.isEmpty) return;

    final timestampMicros = DateTime.now().microsecondsSinceEpoch;

    // 8 bytes (Int64 timestamp) + 4 bytes (Uint32 length) = 12-byte header
    final header = ByteData(12)
      ..setInt64(0, timestampMicros, Endian.big)
      ..setUint32(8, bytes.length, Endian.big);

    _sink!.add(header.buffer.asUint8List());
    _sink!.add(bytes);
    _bytesWritten += 12 + bytes.length;
    _chunksWritten++;
  }

  /// Buffers one operator uplink attempt for the file's trailing command
  /// section (flushed on [stop]). No-op outside a session.
  void recordCommand(SentCommand command) {
    if (_sink == null) return;
    _commands.add(command);
  }
}
