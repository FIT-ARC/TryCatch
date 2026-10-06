import 'package:serial/serial.dart';

/// One fixed-width time bin of a recording's channel profile: raw byte
/// counters decoded from the recorded chunk stream (garbage included — the
/// saved chunks are the verbatim radio traffic, same as live).
class ChannelBin {
  /// Start offset from the recording start, in milliseconds.
  final int startMs;

  final int durationMs;
  final int matchedBytes;
  final int unmatchedBytes;
  final int matchedPackets;
  final int crcErrors;

  const ChannelBin({
    required this.startMs,
    required this.durationMs,
    this.matchedBytes = 0,
    this.unmatchedBytes = 0,
    this.matchedPackets = 0,
    this.crcErrors = 0,
  });

  double get _dtS => durationMs / 1000.0;
  double get matchedBps => matchedBytes / _dtS;
  double get unmatchedBps => unmatchedBytes / _dtS;
  double get packetRate => matchedPackets / _dtS;
}

/// Buckets raw recording [chunks] into fixed-width bins by feeding them
/// through the recording connector's parser — the same framing as the live
/// path, so a replay shows the same unknown-bytes/s picture the live
/// monitor did.
///
/// Gaps with no chunks become zero bins, keeping the time axis continuous.
List<ChannelBin> buildChannelProfile(
  List<RecordingChunk> chunks, {
  int binMs = 500,
  TelemetryConnector? connector,
  void Function(List<TelemetryFrame>)? onFrames,
}) {
  if (chunks.isEmpty) return const [];
  if (binMs <= 0) throw ArgumentError.value(binMs, 'binMs');
  final t0 = chunks.first.tsMs;
  var lastTimestamp = t0;
  for (final chunk in chunks) {
    if (chunk.tsMs < lastTimestamp) {
      throw const FormatException(
        'Recording timestamps are not chronological.',
      );
    }
    lastTimestamp = chunk.tsMs;
  }
  // Keep dense profiles bounded even for sparse or corrupt timestamps.
  const maxBins = 20000;
  final minimumBinMs = (lastTimestamp - t0) ~/ (maxBins - 1) + 1;
  if (minimumBinMs > binMs) binMs = minimumBinMs;
  final parser = (connector ?? mockConnector).createParser();
  // Per-bin accumulators, grown on demand.
  final matched = <int>[];
  final unmatched = <int>[];
  final packets = <int>[];
  final crcs = <int>[];
  var prevMatched = 0;
  var prevUnmatched = 0;
  var prevPackets = 0;
  var prevCrcs = 0;
  var maxBin = 0;

  void ensure(int bin) {
    while (matched.length <= bin) {
      matched.add(0);
      unmatched.add(0);
      packets.add(0);
      crcs.add(0);
    }
    if (bin > maxBin) maxBin = bin;
  }

  for (final chunk in chunks) {
    final bin = ((chunk.tsMs - t0) ~/ binMs).clamp(0, 1 << 30);
    ensure(bin);
    final frames = parser.feed(chunk.payload, timestampMs: chunk.tsMs);
    onFrames?.call(frames);
    matched[bin] += parser.matchedBytes - prevMatched;
    unmatched[bin] +=
        (parser.garbageBytes + parser.crcErrorBytes) - prevUnmatched;
    packets[bin] += parser.matchedPackets - prevPackets;
    crcs[bin] += parser.crcErrorCount - prevCrcs;
    prevMatched = parser.matchedBytes;
    prevUnmatched = parser.garbageBytes + parser.crcErrorBytes;
    prevPackets = parser.matchedPackets;
    prevCrcs = parser.crcErrorCount;
  }

  return [
    for (var i = 0; i <= maxBin; i++)
      ChannelBin(
        startMs: i * binMs,
        durationMs: binMs,
        matchedBytes: matched[i],
        unmatchedBytes: unmatched[i],
        matchedPackets: packets[i],
        crcErrors: crcs[i],
      ),
  ];
}
