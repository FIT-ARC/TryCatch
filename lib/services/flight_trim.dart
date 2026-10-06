import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:serial/serial.dart';

import '../foundation/time/decimation.dart';
import '../foundation/time/time_series.dart';

/// Raw recording chunk I/O + trimming ("save part of a flight").
///
/// Recording files open with a fixed v3 [RecordingHeader] (with a section
/// directory + connector stamp) followed by a flat stream of chunks: a
/// 12-byte header (i64 microseconds big-endian + u32 payload length
/// big-endian) + payload, then the trailing command log.
/// The recorder stores *raw stream fragments* (whatever bytes arrived in one
/// serial read), NOT one frame per chunk — so chunk payloads must be
/// reassembled with the recording connector's parser before they become
/// [TelemetryFrame]s. Trimming copies a time slice verbatim, so the result
/// replays like any recording (replay clocks are relative to the first
/// chunk), and writes a fresh header carrying the source's launch site +
/// connector id over the kept stats plus the sliced command log.
///
/// Chunk I/O itself ([RecordingChunk], [readRecordingChunks],
/// [writeRecordingChunks]) lives in the serial package next to the header
/// codec; this file keeps the trim + preview-decode logic.

/// Copies the [startMs]..[endMs] slice (relative to the first chunk) of
/// [srcPath] into [dstPath]. Returns the kept chunk count (0 when empty or
/// the window covers nothing — no file is written then).
///
/// The destination gets a fresh header: stats recomputed over the kept
/// slice, launch site + connector id propagated from the source header
/// (required — a siteless source is a legacy file and cannot be trimmed),
/// and the filed command log sliced to the same window.
Future<int> trimRecording({
  required String srcPath,
  required String dstPath,
  required int startMs,
  required int endMs,
}) async {
  final srcHeader = await tryReadRecordingHeader(srcPath);
  final srcLaunch = srcHeader?.launchRef;
  if (srcLaunch == null) {
    throw StateError('Source recording has no launch site.');
  }
  final srcConnectorId = srcHeader?.connectorId ?? '';
  if (connectorById(srcConnectorId) == null) {
    throw StateError('Source recording uses an unknown connector.');
  }
  final chunks = await readRecordingChunks(srcPath);
  if (chunks.isEmpty) return 0;
  final t0 = chunks.first.tsMs;
  final kept = [
    for (final c in chunks)
      if (c.tsMs - t0 >= startMs && c.tsMs - t0 <= endMs) c,
  ];
  if (kept.isEmpty) return 0;
  final commands = [
    for (final cmd in await readRecordingCommands(srcPath))
      if (cmd.tsMs - t0 >= startMs && cmd.tsMs - t0 <= endMs) cmd,
  ];
  try {
    await writeRecordingFile(
      dstPath,
      RecordingHeader(
        payloadLength:
            connectorById(srcConnectorId)?.framingPayloadLength ??
            TelemetryFraming.payloadLength,
        connectorId: srcConnectorId,
      ),
      kept,
      commands: commands,
    );
    await finalizeRecordingFile(
      dstPath,
      launch: srcLaunch,
      connectorId: srcConnectorId,
      commands: commands,
    );
  } catch (_) {
    try {
      await File(dstPath).delete();
    } catch (_) {}
    rethrow;
  }
  return kept.length;
}

/// One decimated position sample for 3D previews: WGS84 + baro altitude.
class TrackPoint {
  final double lat;
  final double lon;
  final double alt;

  const TrackPoint({required this.lat, required this.lon, required this.alt});
}

/// Frames decoded from a recording, oldest first.
class DecodedFlight {
  final List<TelemetryFrame> frames;

  const DecodedFlight(this.frames);

  bool get isEmpty => frames.isEmpty;
}

/// Reassembles the raw stream fragments of a recording into internal
/// frames with the recording's own connector, oldest first.
///
/// Files without a valid header (or with an unknown connector) yield an
/// empty flight — callers keep whatever preview they already have.
Future<DecodedFlight> decodeRecordingFrames(String path) async {
  final header = await tryReadRecordingHeader(path);
  final connector = header == null ? null : connectorById(header.connectorId);
  if (connector == null) {
    return const DecodedFlight([]);
  }
  final chunks = await readRecordingChunks(path);
  final parser = connector.createParser();
  final frames = <TelemetryFrame>[];
  for (final chunk in chunks) {
    frames.addAll(parser.feed(chunk.payload, timestampMs: chunk.tsMs));
  }
  return frames.isNotEmpty ? DecodedFlight(frames) : const DecodedFlight([]);
}

/// [decodeRecordingFrames] for a recording held in memory (bundled asset):
/// same connector-driven reassembly, no file on disk.
Future<DecodedFlight> decodeRecordingFramesFromBytes(Uint8List bytes) async {
  final data = decodeRecordingBytes(bytes);
  final connector = data == null
      ? null
      : connectorById(data.header.connectorId);
  if (data == null || connector == null) {
    return const DecodedFlight([]);
  }
  final parser = connector.createParser();
  final frames = <TelemetryFrame>[];
  for (final chunk in data.chunks) {
    frames.addAll(parser.feed(chunk.payload, timestampMs: chunk.tsMs));
  }
  return frames.isNotEmpty ? DecodedFlight(frames) : const DecodedFlight([]);
}

/// One decimated altitude sample: barometric altitude at [timeMs], a
/// flight-clock offset from the first decoded frame.
///
/// Pairing each value with its own timestamp keeps a spiky profile aligned
/// with the flight-event markers even when frames are unevenly spaced — a
/// long idle gap before or after the flight no longer stretches the flight
/// part across the whole chart.
class AltitudePoint {
  final int timeMs;
  final double altitude;

  const AltitudePoint(this.timeMs, this.altitude);
}

/// Target number of points in a decimated altitude profile.
const int maxAltProfilePoints = 160;

/// Decimates baro altitudes for thumbnails/graphs (≤[maxAltProfilePoints]
/// points), tagging every point with its flight-clock time.
///
/// Short flights keep every frame. Longer ones bucket by time and keep each
/// bucket's minimum and maximum (spike-safe, so a narrow apogee is not
/// skipped), and the resulting x positions follow the recording clock rather
/// than frame order.
List<AltitudePoint> buildAltProfile(List<TelemetryFrame> frames) {
  if (frames.isEmpty) return const [];
  final t0 = frames.first.receivedAtMs;
  List<AltitudePoint> tagged(Iterable<TelemetryFrame> source) => [
    for (final frame in source)
      AltitudePoint(frame.receivedAtMs - t0, frame.baroAltitude),
  ];
  if (frames.length <= maxAltProfilePoints) return tagged(frames);
  final spanMs = frames.last.receivedAtMs - t0;
  final bucketMs = math.max(1, spanMs ~/ (maxAltProfilePoints ~/ 2));
  final series = ListTimeSeries<TelemetryFrame>(
    (frame) => frame.receivedAtMs,
    frames,
  );
  final decimated = decimate<TelemetryFrame>(
    series,
    (frame) => (frame.receivedAtMs - t0) ~/ bucketMs,
    [(frame) => frame.baroAltitude],
    maxPoints: maxAltProfilePoints,
  );
  return tagged(decimated);
}

/// Decimates GPS fixes for 3D previews (≤160 points, oldest first).
List<TrackPoint> buildTrackProfile(List<TelemetryFrame> frames) {
  final fixes = [
    for (final f in frames)
      if (f.gpsHasFix)
        TrackPoint(lat: f.latitude, lon: f.longitude, alt: f.baroAltitude),
  ];
  return [
    for (final index in strideStableIndices(fixes.length, 160)) fixes[index],
  ];
}
