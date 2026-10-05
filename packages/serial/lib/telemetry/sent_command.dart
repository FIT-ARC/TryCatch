import 'dart:typed_data';

/// Outcome of one operator uplink attempt.
enum CommandStatus {
  /// Bytes went out on the wire.
  sent,

  /// Attempt never reached the rocket (not connected, send failed...).
  failed;

  /// Maps a stored wire value back to a status, defaulting to [failed].
  static CommandStatus fromValue(int v) =>
      v == 0 ? CommandStatus.sent : CommandStatus.failed;
}

/// UI surface that initiated the uplink.
enum CommandSource {
  /// Unknown / legacy (e.g. migrated files have no commands at all).
  unknown,

  /// Control-panel two-click button.
  controlPanel,

  /// FSM state-request chip.
  fsm;

  /// Maps a stored wire value back to a source, defaulting to [unknown].
  static CommandSource fromValue(int v) => switch (v) {
        1 => CommandSource.controlPanel,
        2 => CommandSource.fsm,
        _ => CommandSource.unknown,
      };
}

/// One operator command sent (or attempted) to the rocket.
///
/// Stored verbatim in the recording's command section: the 4 raw uplink
/// bytes (`54 43 cmd arg`) plus the attempt timestamp, outcome and source.
/// The human-readable label is resolved at display time via the active
/// connector's `describeCommand` so catalog renames never invalidate old
/// recordings.
class SentCommand {
  /// Attempt time, microseconds since epoch (same clock as chunk stamps).
  final int tsUs;

  /// Exact 4 uplink bytes as transmitted (or attempted).
  final List<int> bytes;

  final CommandStatus status;
  final CommandSource source;

  const SentCommand({
    required this.tsUs,
    required this.bytes,
    this.status = CommandStatus.sent,
    this.source = CommandSource.unknown,
  });

  /// Attempt time, milliseconds since epoch.
  int get tsMs => tsUs ~/ 1000;

  /// Alias matching [TelemetryFrame.receivedAtMs] so live tiles can share
  /// their "N s ago" helpers.
  int get receivedAtMs => tsMs;

  /// Fixed on-disk record size in bytes.
  static const int recordLength = 16;

  /// Serializes to exactly [recordLength] bytes (big-endian):
  /// i64 tsUs + 4 raw bytes + u8 status + u8 source + 2 reserved.
  Uint8List encode() {
    final b = ByteData(recordLength);
    b.setInt64(0, tsUs, Endian.big);
    final raw = bytes.length >= 4 ? bytes.sublist(bytes.length - 4) : bytes;
    final out = b.buffer.asUint8List();
    out.setRange(8, 8 + raw.length, raw);
    out[12] = status.index;
    out[13] = source.index;
    return out;
  }

  /// Parses one [recordLength]-byte record (`null` when malformed).
  static SentCommand? decode(Uint8List record) {
    if (record.length < recordLength) return null;
    final b = ByteData.sublistView(record, 0, recordLength);
    if (b.getUint16(14, Endian.big) != 0) return null;
    return SentCommand(
      tsUs: b.getInt64(0, Endian.big),
      bytes: Uint8List.fromList(record.sublist(8, 12)),
      status: CommandStatus.fromValue(record[12]),
      source: CommandSource.fromValue(record[13]),
    );
  }

  @override
  String toString() =>
      'SentCommand(${bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}, $status, $source @ $tsMs)';
}
