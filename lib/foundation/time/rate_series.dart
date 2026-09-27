import 'package:serial/serial.dart';

import '../app_log.dart';
import 'time_series.dart';
import 'timed_sample.dart';
import 'window.dart';

/// One per-snapshot rate point, derived from [LinkStats] counter deltas.
class RateSample with TimedSample {
  @override
  final int timestampMs;
  final double matchedBps;
  final double unmatchedBps;
  final double packetRate;

  /// Cumulative matched packets at snapshot time, for exact windowed means.
  final int matchedPackets;

  const RateSample({
    required this.timestampMs,
    required this.matchedBps,
    required this.unmatchedBps,
    required this.packetRate,
    this.matchedPackets = 0,
  });
}

/// Verdict on unknown traffic. Thresholds match legacy ChannelThresholds.
enum RateVerdict { clear, activity, interference }

RateVerdict verdictFor(double unmatchedBps) {
  if (unmatchedBps >= 400) return RateVerdict.interference;
  if (unmatchedBps >= 50) return RateVerdict.activity;
  return RateVerdict.clear;
}

/// Single owner of link-rate history. Replaces PacketRateTracker +
/// ChannelHealthTracker + per-widget private trackers.
///
/// Fed from cumulative [LinkStats]; counter rewind (reconnect) re-baselines
/// without emitting a bogus sample, keeping history so the age readout
/// survives reconnects.
class RateSeries extends RingTimeSeries<RateSample> {
  LinkStats? _prev;

  RateSeries({int capacity = 240})
      : super(capacity, (s) => s.timestampMs);

  RateSample? get latest => isEmpty ? null : newest(0);

  RateSample? addSnapshot(LinkStats next) {
    final prev = _prev;
    _prev = next;
    if (prev == null) return null;
    // Worker reset (reconnect): counters restarted. Re-baseline without
    // dropping history, so the age readout ("last packet N s ago")
    // survives reconnects instead of flashing "no data".
    if (next.totalBytes < prev.totalBytes ||
        next.matchedBytes < prev.matchedBytes ||
        next.timestampMs <= prev.timestampMs) {
      return null;
    }
    final dtS = (next.timestampMs - prev.timestampMs) / 1000.0;
    if (dtS <= 0) return null;
    final sample = RateSample(
      timestampMs: next.timestampMs,
      matchedBps: (next.matchedBytes - prev.matchedBytes) / dtS,
      unmatchedBps: (next.unmatchedBytes - prev.unmatchedBytes) / dtS,
      packetRate:
          (next.matchedPackets - prev.matchedPackets).clamp(0, 1 << 30) / dtS,
      matchedPackets: next.matchedPackets,
    );
    push(sample);
    return sample;
  }

  @override
  void clear() {
    super.clear();
    _prev = null;
  }

  /// Live label: windowed rate while fresh, age after 2s silence, no-data
  /// before first. The rate is the generic windowed mean over cumulative
  /// counters (see `rateOverWindow`), never one instantaneous slice.
  String label({int? nowMs, Duration window = const Duration(seconds: 2)}) {
    final last = latest;
    if (last == null) return 'no data';
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final ageMs = now - last.timestampMs;
    final shown = rateOverWindow(
      this,
      (s) => s.matchedPackets,
      nowMs: now,
      window: window,
      fallback: last.packetRate,
    ).toStringAsFixed(1);
    if (ageMs < 0) {
      AppLog.warn('RateSeries label clock skew: $ageMs ms');
      return '$shown pkt/s';
    }
    if (ageMs <= window.inMilliseconds) {
      return '$shown pkt/s';
    }
    if (ageMs < 1000) return '$ageMs ms ago';
    final s = ageMs / 1000;
    if (s < 60) return '${s.toStringAsFixed(1)} s ago';
    return '${(s ~/ 60)}m ${(s % 60).round()}s ago';
  }
}

/// Human rate: 950 -> "950 B/s", 2400 -> "2.4 kB/s".
String formatBps(double bps) {
  if (bps < 1000) return '${bps.round()} B/s';
  if (bps < 10000) return '${(bps / 1000).toStringAsFixed(1)} kB/s';
  return '${(bps / 1000).round()} kB/s';
}
