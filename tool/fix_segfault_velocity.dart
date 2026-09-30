/// Recomputes vertical velocity in a SegFault-framed recording.
///
/// The v1 Kalman velocity state can lock to a biased value (e.g. after the
/// airframe tips over, the frozen launch accel bias integrates into a
/// permanent negative offset). This rebuilds the bytestream packet by
/// packet, replacing only the `kfVerticalVelocity` field (bytes 29-30,
/// 0.1 m/s) with a smoothed central difference of the transmitted AGL
/// altitude over chunk wall-clock time, so velocity reads ~0 when altitude
/// is flat. Every other byte — including the firmware timestamp, packet
/// id, IMU and GPS fields — is preserved, as are chunk boundaries,
/// timestamps, launch site and command log.
///
/// Usage:
/// ```sh
/// dart run tool/fix_segfault_velocity.dart <segfault-input.bin> <output.bin>
/// ```
/// Inputs are never modified.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:serial/serial.dart';

/// Half-width in seconds of the median prefilter window. Rejects
/// single-packet baro artifacts (e.g. the ejection-charge pressure dip at
/// apogee) while preserving real motion.
const double _medianHalfWindowS = 0.15;

/// Half-width in seconds of the least-squares slope window. Time-based, so
/// irregular packet spacing (telemetry blackouts, backlogged flushes)
/// cannot produce phantom spikes the way index-based differences do.
const double _slopeHalfWindowS = 0.4;

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
        'Usage: dart run tool/fix_segfault_velocity.dart <segfault-input.bin> <output.bin>');
    exitCode = 2;
    return;
  }
  final inputPath = args[0];
  final outputPath = args[1];

  final header = await tryReadRecordingHeader(inputPath);
  if (header == null) {
    stderr.writeln('Not a recording: $inputPath');
    exitCode = 2;
    return;
  }
  if (header.connectorId != segfaultConnector.id) {
    stderr.writeln(
        'Expected a ${segfaultConnector.id}-framed input, found ${header.connectorId}; refusing.');
    exitCode = 2;
    return;
  }
  final launch = header.launchRef;
  if (launch == null) {
    stderr.writeln('Recording has no launch site; refusing.');
    exitCode = 2;
    return;
  }

  final chunks = await readRecordingChunks(inputPath);
  if (chunks.isEmpty) {
    stderr.writeln('No telemetry chunks.');
    exitCode = 2;
    return;
  }

  // Split the raw stream into 33-byte packets, sync-hunting exactly like
  // the connector parser. Each packet takes the timestamp of the chunk
  // that completed it.
  final packets = <Uint8List>[];
  final packetTimesUs = <int>[];
  final buf = <int>[];
  for (final chunk in chunks) {
    buf.addAll(chunk.payload);
    while (buf.length >= SegfaultFraming.totalPacketLength) {
      final start = _indexOfSync(buf);
      if (start == -1) {
        final last = buf.last;
        buf.clear();
        buf.add(last);
        break;
      }
      if (start > 0) buf.removeRange(0, start);
      if (buf.length < SegfaultFraming.totalPacketLength) break;
      packets.add(
          Uint8List.fromList(buf.sublist(0, SegfaultFraming.totalPacketLength)));
      packetTimesUs.add(chunk.tsUs);
      buf.removeRange(0, SegfaultFraming.totalPacketLength);
    }
  }
  if (buf.length > 1 || packets.isEmpty) {
    stderr.writeln(
        'Framing residue (${buf.length} bytes) or no packets; refusing.');
    exitCode = 2;
    return;
  }

  final n = packets.length;
  final agl = List<double>.generate(n, (i) {
    final b = ByteData.sublistView(packets[i]);
    return b.getInt16(18, Endian.little) / 10.0;
  });
  final t = List<double>.generate(
      n, (i) => packetTimesUs[i] / 1000000.0);

  // Time-windowed velocity: median-prefilter the altitude (rejects
  // single-packet spikes), then take the least-squares slope over a
  // symmetric time window. Both windows are time-based, so blackouts and
  // backlogged packet bursts cannot skew the result.
  final despiked = List<double>.generate(n, (i) {
    final vals = <double>[];
    for (var j = 0; j < n; j++) {
      if ((t[j] - t[i]).abs() <= _medianHalfWindowS) vals.add(agl[j]);
    }
    vals.sort();
    return vals[vals.length ~/ 2];
  });
  double velocityAt(int i) {
    var sumT = 0.0;
    var sumA = 0.0;
    var count = 0;
    for (var j = 0; j < n; j++) {
      if ((t[j] - t[i]).abs() <= _slopeHalfWindowS) {
        sumT += t[j];
        sumA += despiked[j];
        count++;
      }
    }
    if (count < 2) return 0;
    final meanT = sumT / count;
    final meanA = sumA / count;
    var num = 0.0;
    var den = 0.0;
    for (var j = 0; j < n; j++) {
      if ((t[j] - t[i]).abs() <= _slopeHalfWindowS) {
        final dt = t[j] - meanT;
        num += dt * (despiked[j] - meanA);
        den += dt * dt;
      }
    }
    if (den <= 0) return 0;
    return num / den;
  }

  final fixedPackets = <Uint8List>[];
  for (var i = 0; i < n; i++) {
    final out = Uint8List.fromList(packets[i]);
    final v = (velocityAt(i) * 10).round().clamp(-0x8000, 0x7FFF);
    ByteData.sublistView(out).setInt16(29, v, Endian.little);
    fixedPackets.add(out);
  }

  // Re-chunk on the original boundaries (lengths must tile the stream).
  final fixedRaw = fixedPackets.expand((p) => p).toList();
  var cursor = 0;
  final outChunks = <RecordingChunk>[];
  for (final chunk in chunks) {
    final len = chunk.payload.length;
    if (cursor + len > fixedRaw.length) {
      stderr.writeln('Chunk layout mismatch; refusing.');
      exitCode = 2;
      return;
    }
    outChunks.add(RecordingChunk(
      tsUs: chunk.tsUs,
      payload: Uint8List.fromList(fixedRaw.sublist(cursor, cursor + len)),
    ));
    cursor += len;
  }
  if (cursor != fixedRaw.length) {
    stderr.writeln('Chunk layout mismatch; refusing.');
    exitCode = 2;
    return;
  }

  final commands = await readRecordingCommands(inputPath);
  await writeRecordingFile(
    outputPath,
    RecordingHeader(
      payloadLength: segfaultConnector.framingPayloadLength,
      connectorId: segfaultConnector.id,
    ),
    outChunks,
    commands: commands,
  );
  final finalHeader = await finalizeRecordingFile(
    outputPath,
    launch: launch,
    connectorId: segfaultConnector.id,
    commands: commands,
  );
  if (finalHeader == null) {
    stderr.writeln('Finalize failed.');
    exitCode = 2;
    return;
  }
  final oldTail = ByteData.sublistView(packets.last).getInt16(29, Endian.little) / 10.0;
  final newTail =
      ByteData.sublistView(fixedPackets.last).getInt16(29, Endian.little) / 10.0;
  stdout.writeln('fixed $n packets -> $outputPath '
      'packets=${finalHeader.packetCount} '
      'maxAlt=${finalHeader.maxBaroAltM.toStringAsFixed(1)}m '
      'tailVv: ${oldTail.toStringAsFixed(1)} -> ${newTail.toStringAsFixed(1)} m/s');
}

int _indexOfSync(List<int> buf) {
  final limit = buf.length - 1;
  for (var i = 0; i < limit; i++) {
    if (buf[i] == SegfaultFraming.startByte0 &&
        buf[i + 1] == SegfaultFraming.startByte1) {
      return i;
    }
  }
  return -1;
}
