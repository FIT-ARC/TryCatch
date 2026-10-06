/// Recording file format v3: fixed header + telemetry chunk stream +
/// command log.
///
/// Layout (all big-endian, header is 168 bytes):
///
/// | Off | Size | Field           | Type  | Notes                                   |
/// |-----|------|-----------------|-------|-----------------------------------------|
/// | 0   | 4    | magic           | u32   | 0x54435233 ('TCR3')                     |
/// | 4   | 2    | payloadLength   | u16   | Wire framing of the body (per-connector)  |
/// | 6   | 2    | flags           | u16   | Bit 0: launch site present              |
/// |     |      |                 |       | Bit 1: stats present                    |
/// | 8   | 8    | startMicros     | i64   | First chunk timestamp (µs epoch)        |
/// | 16  | 8    | endMicros       | i64   | Last chunk timestamp                    |
/// | 24  | 8    | packetCount     | u64   | Valid decoded frames                    |
/// | 32  | 4    | maxBaroAltM     | f32   | Peak barometric altitude (m AGL)        |
/// | 36  | 4    | maxSpeedMps     | f32   | Peak total speed (m/s)                  |
/// | 40  | 4    | maxAccelMps2    | f32   | Peak total acceleration (m/s²)          |
/// | 44  | 4    | launchLat       | i32   | 1e-7 degrees                          |
/// | 48  | 4    | launchLon       | i32   | 1e-7 degrees                          |
/// | 52  | 4    | launchMslM      | f32   | Site MSL altitude (m)                   |
/// | 56  | 48   | launchName      | u8[48]| UTF-8, NUL-padded, rune-safe truncated |
/// | 104 | 2    | headerCrc       | u16   | CRC16-CCITT over bytes 0..103           |
/// | 106 | 2    | reserved        | u16   | Zero                                      |
/// | 108 | 2    | headerLength    | u16   | Always 168                              |
/// | 110 | 2    | formatVersion   | u16   | Always 3                                |
/// | 112 | 8    | telemetryByteLen| u64   | Telemetry chunk-stream bytes            |
/// | 120 | 8    | commandsOffset  | u64   | Absolute offset of the command section  |
/// | 128 | 4    | commandCount    | u32   | Fixed 16-byte command records following |
/// | 132 | 2    | directoryCrc    | u16   | CRC16-CCITT over 108..131 + 134..167    |
/// | 134 | 2    | reserved        | u16   | Zero                                      |
/// | 136 | 32   | connectorId     | u8[32]| UTF-8, NUL-padded (e.g. 'mock')       |
///
/// Behind the header the file holds the telemetry chunk stream (per chunk
/// a 12-byte header — i64 micros + u32 length, big-endian — + raw stream
/// bytes, exactly `telemetryByteLen` bytes), followed at [commandsOffset]
/// by `commandCount` fixed 16-byte [SentCommand] records. The chunk bytes
/// are the recording connector's raw bytestream and decode with that
/// connector's parser ([connectorId] selects it for playback).
///
/// The header is mandatory — files without the v3 magic (including every
/// v2 `TCR2` recording) are rejected by every reader below. Use
/// `tool/migrate_recordings_v3.dart` to convert v2 files (all stamped
/// with the `mock` connector).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../connectors/registry.dart';
import '../telemetry/frame_codec.dart' show crc16CCITT;
import '../telemetry/sent_command.dart';
import '../worker/protocol.dart';

/// Magic word opening every recording file ('TCR3', format v3).
const int recordingMagic = 0x54435233;

/// Magic word of the legacy v2 format ('TCR2') — rejected by every reader.
/// Kept so the v2→v3 migration tool and rejection tests can name it.
const int recordingMagicV2 = 0x54435232;

/// Fixed header size in bytes (telemetry fields + section directory +
/// connector id).
const int recordingHeaderLength = 168;

/// On-disk format version stamped into the section directory.
const int recordingFormatVersion = 3;

/// Fixed byte size of the connector-id field (UTF-8, NUL-padded).
const int recordingConnectorIdLength = 32;

/// Flag: the launch-site fields carry the launch site (always set — a site
/// is required before recording).
const int recordingFlagLaunchSite = 1 << 0;

/// Flag: the stats fields were computed over the whole body.
const int recordingFlagStats = 1 << 1;

/// Fixed header of a recording file. See the library doc for the layout.
class RecordingHeader {
  /// Wire framing of the body (the recording connector's framing).
  final int payloadLength;

  final bool hasLaunchSite;
  final bool hasStats;

  /// First chunk timestamp, microseconds since epoch (0 when empty).
  final int startMicros;

  /// Last chunk timestamp, microseconds since epoch.
  final int endMicros;

  final int packetCount;
  final double maxBaroAltM;
  final double maxSpeedMps;
  final double maxAccelMps2;

  final double launchLatitude;
  final double launchLongitude;
  final double launchMslM;
  final String launchName;

  /// Telemetry chunk-stream length in bytes (chunk framings + payloads).
  /// Zero on provisional/crash-interrupted headers — readers then treat
  /// everything past the header as telemetry (no command section exists
  /// when [commandCount] is zero).
  final int telemetryByteLen;

  /// Absolute file offset of the first command record.
  final int commandsOffset;

  /// Number of fixed 16-byte [SentCommand] records at [commandsOffset].
  final int commandCount;

  /// Stable id of the connector the body was recorded with (e.g. `'mock'`).
  /// Playback auto-selects this connector to decode the chunk stream and to
  /// resolve states/commands/events. Empty on headers that predate the
  /// connector stamp (never written by v3 code — only a defensive default).
  final String connectorId;

  const RecordingHeader({
    this.payloadLength = 0,
    this.hasLaunchSite = false,
    this.hasStats = false,
    this.startMicros = 0,
    this.endMicros = 0,
    this.packetCount = 0,
    this.maxBaroAltM = 0,
    this.maxSpeedMps = 0,
    this.maxAccelMps2 = 0,
    this.launchLatitude = 0,
    this.launchLongitude = 0,
    this.launchMslM = 0,
    this.launchName = '',
    this.telemetryByteLen = 0,
    this.commandsOffset = 0,
    this.commandCount = 0,
    this.connectorId = '',
  });

  /// Flight duration covered by the body, in milliseconds.
  int get durationMs =>
      endMicros >= startMicros ? (endMicros - startMicros) ~/ 1000 : 0;

  /// Launch site as a [LaunchRef], or `null` when the flag is clear.
  LaunchRef? get launchRef => hasLaunchSite
      ? LaunchRef(
          latitude: launchLatitude,
          longitude: launchLongitude,
          mslM: launchMslM,
          name: launchName,
        )
      : null;

  /// Returns a copy with the section directory filled in.
  RecordingHeader withDirectory({
    required int telemetryByteLen,
    required int commandsOffset,
    required int commandCount,
  }) => RecordingHeader(
    payloadLength: payloadLength,
    hasLaunchSite: hasLaunchSite,
    hasStats: hasStats,
    startMicros: startMicros,
    endMicros: endMicros,
    packetCount: packetCount,
    maxBaroAltM: maxBaroAltM,
    maxSpeedMps: maxSpeedMps,
    maxAccelMps2: maxAccelMps2,
    launchLatitude: launchLatitude,
    launchLongitude: launchLongitude,
    launchMslM: launchMslM,
    launchName: launchName,
    telemetryByteLen: telemetryByteLen,
    commandsOffset: commandsOffset,
    commandCount: commandCount,
    connectorId: connectorId,
  );

  /// Serializes to exactly [recordingHeaderLength] bytes.
  Uint8List encode() {
    final b = ByteData(recordingHeaderLength);
    b.setUint32(0, recordingMagic, Endian.big);
    b.setUint16(4, payloadLength, Endian.big);
    var flags = 0;
    if (hasLaunchSite) flags |= recordingFlagLaunchSite;
    if (hasStats) flags |= recordingFlagStats;
    b.setUint16(6, flags, Endian.big);
    b.setInt64(8, startMicros, Endian.big);
    b.setInt64(16, endMicros, Endian.big);
    b.setUint64(24, packetCount, Endian.big);
    b.setFloat32(32, maxBaroAltM, Endian.big);
    b.setFloat32(36, maxSpeedMps, Endian.big);
    b.setFloat32(40, maxAccelMps2, Endian.big);
    b.setInt32(
      44,
      (launchLatitude.clamp(-90.0, 90.0) / 1e-7).round(),
      Endian.big,
    );
    b.setInt32(
      48,
      (launchLongitude.clamp(-180.0, 180.0) / 1e-7).round(),
      Endian.big,
    );
    b.setFloat32(52, launchMslM, Endian.big);
    final nameBytes = _truncateUtf8(launchName, 48);
    b.buffer.asUint8List().setRange(56, 56 + nameBytes.length, nameBytes);
    b.setUint16(104, crc16CCITT(b.buffer.asUint8List(), 0, 104), Endian.big);
    b.setUint16(106, 0, Endian.big);
    b.setUint16(108, recordingHeaderLength, Endian.big);
    b.setUint16(110, recordingFormatVersion, Endian.big);
    b.setUint64(112, telemetryByteLen, Endian.big);
    b.setUint64(120, commandsOffset, Endian.big);
    b.setUint32(128, commandCount, Endian.big);
    b.setUint16(134, 0, Endian.big);
    final connectorBytes = _truncateUtf8(
      connectorId,
      recordingConnectorIdLength,
    );
    b.buffer.asUint8List().setRange(
      136,
      136 + connectorBytes.length,
      connectorBytes,
    );
    b.setUint16(132, _directoryCrc(b.buffer.asUint8List()), Endian.big);
    return b.buffer.asUint8List();
  }

  /// CRC16-CCITT over the section directory, skipping the CRC field itself:
  /// bytes 108..131 followed by 134..167 (covers the connector id).
  static int _directoryCrc(Uint8List bytes) {
    var crc = 0xFFFF;
    for (var i = 108; i < recordingHeaderLength; i++) {
      if (i == 132 || i == 133) continue;
      crc ^= bytes[i] << 8;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
        crc &= 0xFFFF;
      }
    }
    return crc;
  }

  /// Parses and validates header bytes (`null` when malformed, the magic
  /// mismatches — including v1/v2 files — or either CRC mismatches).
  static RecordingHeader? decode(Uint8List bytes) {
    if (bytes.length < recordingHeaderLength) return null;
    final b = ByteData.sublistView(bytes, 0, recordingHeaderLength);
    if (b.getUint32(0, Endian.big) != recordingMagic) return null;
    if (b.getUint16(104, Endian.big) != crc16CCITT(bytes, 0, 104)) {
      return null;
    }
    if (b.getUint16(108, Endian.big) != recordingHeaderLength ||
        b.getUint16(110, Endian.big) != recordingFormatVersion) {
      return null;
    }
    if (b.getUint16(132, Endian.big) != _directoryCrc(bytes)) {
      return null;
    }
    final flags = b.getUint16(6, Endian.big);
    final nameBytes = bytes.sublist(56, 104);
    var nameEnd = nameBytes.indexOf(0);
    if (nameEnd < 0) nameEnd = nameBytes.length;
    final connectorBytes = bytes.sublist(136, 136 + recordingConnectorIdLength);
    var connectorEnd = connectorBytes.indexOf(0);
    if (connectorEnd < 0) connectorEnd = connectorBytes.length;
    return RecordingHeader(
      payloadLength: b.getUint16(4, Endian.big),
      hasLaunchSite: flags & recordingFlagLaunchSite != 0,
      hasStats: flags & recordingFlagStats != 0,
      startMicros: b.getInt64(8, Endian.big),
      endMicros: b.getInt64(16, Endian.big),
      packetCount: b.getUint64(24, Endian.big),
      maxBaroAltM: b.getFloat32(32, Endian.big),
      maxSpeedMps: b.getFloat32(36, Endian.big),
      maxAccelMps2: b.getFloat32(40, Endian.big),
      launchLatitude: b.getInt32(44, Endian.big) * 1e-7,
      launchLongitude: b.getInt32(48, Endian.big) * 1e-7,
      launchMslM: b.getFloat32(52, Endian.big),
      launchName: utf8.decode(
        nameBytes.sublist(0, nameEnd),
        allowMalformed: true,
      ),
      telemetryByteLen: b.getUint64(112, Endian.big),
      commandsOffset: b.getUint64(120, Endian.big),
      commandCount: b.getUint32(128, Endian.big),
      connectorId: utf8.decode(
        connectorBytes.sublist(0, connectorEnd),
        allowMalformed: true,
      ),
    );
  }

  /// Truncates [s] to fit [maxBytes] of UTF-8 without splitting a rune.
  static Uint8List _truncateUtf8(String s, int maxBytes) {
    final out = <int>[];
    for (final rune in s.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune));
      if (out.length + encoded.length > maxBytes) break;
      out.addAll(encoded);
    }
    return Uint8List.fromList(out);
  }
}

/// Body offset of a recording file: the fixed header length when the v2
/// magic is present, else 0 (not a recording — rejected by every reader).
int recordingBodyOffsetOf(Uint8List prefix, int fileLength) {
  if (prefix.length < 12) return 0;
  final b = ByteData.sublistView(prefix, 0, 12);
  if (b.getUint32(0, Endian.big) != recordingMagic) return 0;
  if (recordingHeaderLength > fileLength) return 0;
  return recordingHeaderLength;
}

/// Reads and validates the file header of [path], or `null` for corrupt
/// or non-recording files (including v1 recordings).
Future<RecordingHeader?> tryReadRecordingHeader(String path) async {
  try {
    final file = File(path);
    final length = await file.length();
    if (length < recordingHeaderLength) return null;
    final raf = await file.open();
    try {
      final bytes = await raf.read(recordingHeaderLength);
      if (bytes.length < recordingHeaderLength) return null;
      return RecordingHeader.decode(bytes);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

/// One raw chunk with its original capture timestamp.
class RecordingChunk {
  /// Capture time, microseconds since epoch (preserved verbatim on write).
  final int tsUs;
  final Uint8List payload;

  const RecordingChunk({required this.tsUs, required this.payload});

  int get tsMs => tsUs ~/ 1000;
}

/// Telemetry byte range of a recording: `[start, end)` absolute offsets.
///
/// Provisional/crash-interrupted headers (`telemetryByteLen == 0` with no
/// command section) fall back to "everything past the header" so partial
/// files stay readable.
(int, int) _telemetryRange(RecordingHeader header, int fileLength) {
  const start = recordingHeaderLength;
  if (header.telemetryByteLen > 0) {
    final end = (start + header.telemetryByteLen).clamp(start, fileLength);
    return (start, end);
  }
  if (header.commandCount > 0) {
    final end = header.commandsOffset.clamp(start, fileLength);
    return (start, end);
  }
  return (start, fileLength);
}

/// Reads every well-formed telemetry chunk of the recording at [path],
/// bounded by the header's section directory and stopping at the first
/// corrupt chunk (same tolerance as the parser). Files without the v2
/// magic yield no chunks.
Future<List<RecordingChunk>> readRecordingChunks(String path) async {
  final header = await tryReadRecordingHeader(path);
  if (header == null) return const [];
  final file = File(path);
  final raf = await file.open();
  try {
    final length = await raf.length();
    final (start, end) = _telemetryRange(header, length);
    if (end <= start) return const [];
    await raf.setPosition(start);
    return await _readChunks(raf, start, end);
  } finally {
    await raf.close();
  }
}

/// Reads the command log of the recording at [path] (empty for
/// command-free or provisional files). Malformed trailing records are
/// ignored; files without the v2 magic yield no commands.
Future<List<SentCommand>> readRecordingCommands(String path) async {
  final header = await tryReadRecordingHeader(path);
  if (header == null || header.commandCount <= 0) return const [];
  try {
    final file = File(path);
    final length = await file.length();
    final offset = header.commandsOffset;
    if (offset < recordingHeaderLength || offset >= length) return const [];
    final available = (length - offset) ~/ SentCommand.recordLength;
    final count = header.commandCount.clamp(0, available);
    if (count <= 0) return const [];
    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      final raw = await raf.read(count * SentCommand.recordLength);
      final out = <SentCommand>[];
      for (var i = 0; i < count; i++) {
        final cmd = SentCommand.decode(
          raw.sublist(
            i * SentCommand.recordLength,
            (i + 1) * SentCommand.recordLength,
          ),
        );
        if (cmd != null) out.add(cmd);
      }
      return out;
    } finally {
      await raf.close();
    }
  } catch (_) {
    return const [];
  }
}

/// A recording parsed from an in-memory byte buffer: its header, telemetry
/// chunks and command log.
class RecordingData {
  final RecordingHeader header;
  final List<RecordingChunk> chunks;
  final List<SentCommand> commands;

  const RecordingData({
    required this.header,
    required this.chunks,
    required this.commands,
  });
}

/// Parses a complete recording held in memory (e.g. a bundled asset),
/// mirroring [tryReadRecordingHeader] / [readRecordingChunks] /
/// [readRecordingCommands] so asset-backed recordings decode identically to
/// files. Returns `null` when the header is missing or invalid.
RecordingData? decodeRecordingBytes(Uint8List bytes) {
  final header = RecordingHeader.decode(bytes);
  if (header == null) return null;
  final (start, end) = _telemetryRange(header, bytes.length);
  final chunks = <RecordingChunk>[];
  var cursor = start;
  while (cursor + 12 <= end) {
    final chunkHeader = ByteData.sublistView(bytes, cursor, cursor + 12);
    final tsUs = chunkHeader.getInt64(0, Endian.big);
    final len = chunkHeader.getUint32(8, Endian.big);
    if (len > 4 * 1024 * 1024 || cursor + 12 + len > end) break;
    chunks.add(
      RecordingChunk(
        tsUs: tsUs,
        payload: Uint8List.sublistView(bytes, cursor + 12, cursor + 12 + len),
      ),
    );
    cursor += 12 + len;
  }
  final commands = <SentCommand>[];
  final offset = header.commandsOffset;
  if (header.commandCount > 0 &&
      offset >= recordingHeaderLength &&
      offset < bytes.length) {
    final available = (bytes.length - offset) ~/ SentCommand.recordLength;
    final count = header.commandCount.clamp(0, available);
    for (var i = 0; i < count; i++) {
      final from = offset + i * SentCommand.recordLength;
      final cmd = SentCommand.decode(
        Uint8List.sublistView(bytes, from, from + SentCommand.recordLength),
      );
      if (cmd != null) commands.add(cmd);
    }
  }
  return RecordingData(header: header, chunks: chunks, commands: commands);
}

/// Walks the chunk stream in `[pos, end)`.
Future<List<RecordingChunk>> _readChunks(
  RandomAccessFile raf,
  int pos,
  int end,
) async {
  final out = <RecordingChunk>[];
  var cursor = pos;
  await raf.setPosition(cursor);
  while (cursor + 12 <= end) {
    final header = ByteData.sublistView(await raf.read(12));
    final tsUs = header.getInt64(0, Endian.big);
    final len = header.getUint32(8, Endian.big);
    // Sanity cap (payloads are ~52 bytes) + truncation guard.
    if (len > 4 * 1024 * 1024 || cursor + 12 + len > end) break;
    final payload = Uint8List.fromList(await raf.read(len));
    out.add(RecordingChunk(tsUs: tsUs, payload: payload));
    cursor += 12 + len;
    if (cursor > 512 * 1024 * 1024) break;
  }
  return out;
}

/// Encodes [chunks] to their on-disk telemetry bytes (framings + payloads).
Uint8List encodeTelemetryBody(List<RecordingChunk> chunks) {
  final builder = BytesBuilder();
  for (final chunk in chunks) {
    final header = ByteData(12)
      ..setInt64(0, chunk.tsUs, Endian.big)
      ..setUint32(8, chunk.payload.length, Endian.big);
    builder.add(header.buffer.asUint8List());
    builder.add(chunk.payload);
  }
  return builder.toBytes();
}

/// Writes [chunks] with their original timestamps (body only, no header —
/// use [writeRecordingFile] for a complete file).
///
/// Note: body-only files have no header and are rejected by every reader;
/// tests use this to assert exactly that.
Future<void> writeRecordingChunks(
  String path,
  List<RecordingChunk> chunks,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final raf = await file.open(mode: FileMode.write);
  try {
    for (final chunk in chunks) {
      final header = ByteData(12)
        ..setInt64(0, chunk.tsUs, Endian.big)
        ..setUint32(8, chunk.payload.length, Endian.big);
      await raf.writeFrom(header.buffer.asUint8List());
      await raf.writeFrom(chunk.payload);
    }
  } finally {
    await raf.close();
  }
}

/// Writes a complete recording file: [header] (with its section directory
/// recomputed from the payloads) + telemetry [chunks] + [commands].
Future<void> writeRecordingFile(
  String path,
  RecordingHeader header,
  List<RecordingChunk> chunks, {
  List<SentCommand> commands = const [],
}) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final body = encodeTelemetryBody(chunks);
  final directory = header.withDirectory(
    telemetryByteLen: body.length,
    commandsOffset: recordingHeaderLength + body.length,
    commandCount: commands.length,
  );
  final raf = await file.open(mode: FileMode.write);
  try {
    await raf.writeFrom(directory.encode());
    await raf.writeFrom(body);
    for (final cmd in commands) {
      await raf.writeFrom(cmd.encode());
    }
  } finally {
    await raf.close();
  }
}

/// Computes the header for the body of [path] and rewrites the file as
/// header + telemetry body + command section.
///
/// An existing header is replaced, so the call is idempotent. A `null`
/// [commands] preserves the already-filed command section (re-finalizing
/// never drops commands by accident); pass an explicit list — possibly
/// empty — to replace it. [connectorId] stamps the recording's connector
/// (stats are computed with that connector's parser). Empty bodies and unknown
/// connectors yield `null`. Bodies without valid packets retain their bytes
/// and commands with `hasStats` false. I/O errors yield `null` unless
/// [throwOnError] is enabled by the recorder to report finalization failures.
Future<RecordingHeader?> finalizeRecordingFile(
  String path, {
  required LaunchRef launch,
  required String connectorId,
  List<SentCommand>? commands,
  bool throwOnError = false,
}) async {
  try {
    final connector = connectorById(connectorId);
    if (connector == null) return null;
    final file = File(path);
    final length = await file.length();
    if (length < 12) return null;
    final header = await tryReadRecordingHeader(path);
    // Headered files re-finalize from their telemetry body; anything else
    // is not a recording and yields null below.
    if (header == null) return null;
    final keptCommands = commands ?? await readRecordingCommands(path);
    final (start, end) = _telemetryRange(header, length);
    final raf = await file.open();
    List<RecordingChunk> chunks;
    try {
      await raf.setPosition(start);
      chunks = await _readChunks(raf, start, end);
    } finally {
      await raf.close();
    }
    if (chunks.isEmpty) return null;

    final parser = connector.createParser();
    var packetCount = 0;
    var maxBaro = double.negativeInfinity;
    var maxSpeed = 0.0;
    var maxAccel = 0.0;
    for (final chunk in chunks) {
      for (final frame in parser.feed(chunk.payload, timestampMs: chunk.tsMs)) {
        packetCount++;
        if (frame.baroAltitude > maxBaro) maxBaro = frame.baroAltitude;
        if (frame.speedTotal > maxSpeed) maxSpeed = frame.speedTotal;
        if (frame.accelTotal > maxAccel) maxAccel = frame.accelTotal;
      }
    }

    final body = encodeTelemetryBody(chunks);
    final finalized = RecordingHeader(
      payloadLength: connector.framingPayloadLength,
      hasLaunchSite: true,
      hasStats: packetCount > 0,
      startMicros: chunks.first.tsUs,
      endMicros: chunks.last.tsUs,
      packetCount: packetCount,
      maxBaroAltM: maxBaro.isFinite ? maxBaro : 0,
      maxSpeedMps: maxSpeed,
      maxAccelMps2: maxAccel,
      launchLatitude: launch.latitude,
      launchLongitude: launch.longitude,
      launchMslM: launch.mslM,
      launchName: launch.name,
      telemetryByteLen: body.length,
      commandsOffset: recordingHeaderLength + body.length,
      commandCount: keptCommands.length,
      connectorId: connector.id,
    );

    final tmp = File('$path.tmp');
    final sink = await tmp.open(mode: FileMode.write);
    try {
      await sink.writeFrom(finalized.encode());
      await sink.writeFrom(body);
      for (final cmd in keptCommands) {
        await sink.writeFrom(cmd.encode());
      }
    } finally {
      await sink.close();
    }
    await tmp.rename(path);
    return finalized;
  } catch (_) {
    if (throwOnError) rethrow;
    return null;
  }
}
