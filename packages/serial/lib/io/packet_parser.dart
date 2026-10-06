import 'dart:typed_data';

import '../constants.dart';
import '../telemetry/frame_codec.dart';
import '../worker/protocol.dart';

/// Stateful byte-stream parser that accumulates incoming chunks and extracts
/// complete [TelemetryPacket] instances based on the configured framing.
///
/// Frames whose trailing CRC16 does not match are treated as garbage and
/// silently dropped — the buffer still advances past them so a corrupt frame
/// cannot desynchronize the stream.
///
/// The parser also keeps cumulative byte counters ([totalBytes],
/// [matchedBytes], [garbageBytes], [crcErrorBytes]) so the UI can report
/// channel health: bytes that arrived on the frequency but never decoded
/// into one of our packets (unknown transmitters, noise).
///
/// [TelemetryFraming.payloadLength] is the single fixed framing; there are
/// no previous framings to parse.
class PacketParser {
  int get payloadLength => TelemetryFraming.payloadLength;

  PacketParser();

  int get _totalPacketLength =>
      TelemetryFraming.startWordLength + payloadLength;

  final _buf = <int>[];
  int _cursor = 0;

  /// Every raw byte ever fed (including garbage and corrupt frames).
  int totalBytes = 0;

  /// Valid packets decoded so far.
  int matchedPackets = 0;

  /// Bytes consumed as valid packets (sync word + payload each).
  int matchedBytes = 0;

  /// Bytes discarded while hunting for the sync word (unknown traffic/noise).
  int garbageBytes = 0;

  /// Frames dropped on CRC mismatch.
  int crcErrorCount = 0;

  /// Bytes consumed by CRC-failed frames (whole packet length each).
  int crcErrorBytes = 0;

  /// Bytes that arrived but never became one of our packets (unknown).
  int get unmatchedBytes => garbageBytes + crcErrorBytes;

  /// Feed a raw byte chunk from the serial stream into the parser.
  ///
  /// Pass optional [timestampMs] when replaying recorded binary streams to preserve
  /// original arrival times. Defaults to [DateTime.now] for live streaming.
  ///
  /// Returns a list of all complete [TelemetryPacket]s extracted.
  List<TelemetryPacket> feed(Uint8List chunk, {int? timestampMs}) {
    totalBytes += chunk.length;
    _buf.addAll(chunk);
    final packets = <TelemetryPacket>[];

    while (_buf.length - _cursor >= _totalPacketLength) {
      final start = _indexOfStartWord();

      if (start == -1) {
        // Retain only the last byte in case the start word was split across chunks.
        // Everything else is unknown traffic on this frequency.
        garbageBytes += _buf.length - _cursor - 1;
        final last = _buf.last;
        _buf.clear();
        _buf.add(last);
        _cursor = 0;
        break;
      }

      if (start > _cursor) {
        // Discard preceding garbage bytes.
        garbageBytes += start - _cursor;
        _cursor = start;
      }

      // Check if we have enough bytes for the complete packet.
      if (_buf.length - _cursor < _totalPacketLength) break;

      // Extract payload bytes.
      final payload = Uint8List.fromList(
        _buf.sublist(
          _cursor + TelemetryFraming.startWordLength,
          _cursor + _totalPacketLength,
        ),
      );

      // Advance buffer past this packet.
      _cursor += _totalPacketLength;

      // Drop frames with a bad CRC.
      if (!FrameCodec.verifyCrc(payload)) {
        crcErrorCount++;
        crcErrorBytes += _totalPacketLength;
        continue;
      }

      matchedPackets++;
      matchedBytes += _totalPacketLength;

      packets.add(
        TelemetryPacket(
          receivedAtMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
          rawData: payload,
        ),
      );
    }

    if (_cursor > 0) {
      _buf.removeRange(0, _cursor);
      _cursor = 0;
    }
    return packets;
  }

  /// Clears the accumulation buffer.
  void reset() {
    _buf.clear();
    _cursor = 0;
  }

  /// Clears the accumulation buffer and all cumulative byte counters.
  void resetStats() {
    reset();
    totalBytes = 0;
    matchedPackets = 0;
    matchedBytes = 0;
    garbageBytes = 0;
    crcErrorCount = 0;
    crcErrorBytes = 0;
  }

  int _indexOfStartWord() {
    final limit = _buf.length - 1;

    for (var i = _cursor; i < limit; i++) {
      if (_buf[i] == TelemetryFraming.startByte0 &&
          _buf[i + 1] == TelemetryFraming.startByte1) {
        return i;
      }
    }

    return -1;
  }
}
