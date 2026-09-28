import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import 'package:dead_reckoning/dead_reckoning.dart';

import '../foundation/store.dart';
import '../core/app_config.dart';
import '../core/dead_reckoning_adapter.dart';
import '../core/flight_stats.dart' as stats;
import '../core/ring_buffer.dart';
import './telemetry_provider.dart';

/// Aggregate of everything the dashboard knows about the current flight.
///
/// [history] and [deadReckoningHistory] are *live views* over the store's
/// ring buffers — they always reflect the newest data without any copying,
/// so tiles can iterate them freely on every build.
class TelemetryState {
  /// Most recently decoded frame, or `null` before the first packet.
  final TelemetryFrame? latest;

  /// Latest dead reckoning position, or `null` before the first GPS fix.
  final DeadReckoningPosition? deadReckoning;

  /// Dead reckoning history (chronological, bounded).
  final RingBuffer<DeadReckoningPosition> deadReckoningHistory;

  /// Capped flight history (chronological, bounded).
  final RingBuffer<TelemetryFrame> history;

  /// Total frames ingested this session (pre-decoded by the connector;
  /// corrupt wire frames never reach the store).
  final int packetCount;

  /// Reserved: decode failures counted here before connectors owned parsing
  /// (kept so persisted/test-constructed states keep compiling).
  final int errorCount;

  /// Human-readable data source ('COM3', 'MOCK', recording file name...).
  final String sourceName;

  /// Whether we are currently replaying a recording.
  final bool replaying;

  TelemetryState({
    required this.history,
    required this.deadReckoningHistory,
    this.latest,
    this.deadReckoning,
    this.packetCount = 0,
    this.errorCount = 0,
    this.sourceName = '',
    this.replaying = false,
  });

  /// Maximum barometric altitude reached so far (m AGL).
  double get maxAltitude =>
      stats.maxBaroAltitude(history, latest?.baroAltitude ?? 0.0);

  /// Maximum total speed reached so far (m/s).
  double get maxSpeed => stats.maxTotalSpeed(history);

  /// Maximum total acceleration reached so far (m/s²).
  double get maxAccel => stats.maxTotalAccel(history);

  /// `receivedAtMs` of the first frame in history, or `null` when empty.
  int? get firstPacketMs =>
      history.isEmpty ? null : history.getChronological(0).receivedAtMs;

  /// Elapsed session time (ms) since the first packet.
  int? get elapsedMs => firstPacketMs == null || latest == null
      ? null
      : latest!.receivedAtMs - firstPacketMs!;
}

/// Single ingestion point for telemetry: subscribes to the serial worker's
/// packet stream, decodes frames, tracks dead reckoning and keeps bounded
/// history + derived stats.
///
/// Tiles watch [telemetryStoreProvider]; replay code calls [ingest]
/// directly. Live streaming starts automatically via the stream subscription.
final telemetryStoreProvider =
    NotifierProvider<TelemetryStore, TelemetryState>(TelemetryStore.new);

class TelemetryStore extends SessionStore<TelemetryState> with StoreTicker {
  static const int _historyCapacity = AppConfig.telemetryHistoryCapacity;

  /// Dead reckoning kicks in only after GPS has been silent this long.
  /// Tiles reuse it to decide when the link (as opposed to just the GPS fix)
  /// has gone stale.
  static const int deadReckoningStaleMs = AppConfig.deadReckoningStaleMs;

  /// Interval between dead reckoning points/ticks.
  static const int deadReckoningUpdateIntervalMs =
      AppConfig.deadReckoningUpdateIntervalMs;

  late RingBuffer<TelemetryFrame> _history;
  late RingBuffer<DeadReckoningPosition> _deadReckoningHistory;

  /// Last packet seen (live only): every dead reckoning projection is a
  /// pure function of this sample plus elapsed time, so the store keeps
  /// the data, not an estimator.
  DeadReckoningSample? _lastPacket;

  /// Frame time of the last packet carrying a GPS fix. History points are
  /// only pushed while the fix is stale, so the map trail fills real GPS
  /// gaps instead of duplicating the live track.
  int? _lastFixMs;

  /// Frame time of the last point pushed to the dead reckoning history.
  int _lastDeadReckoningMs = 0;

  /// Ground-side extrapolation timer while the link itself is silent.
  Timer? _deadReckoningTicker;

  /// Throttle: rebuild the exposed state at most this often (history-heavy
  /// tiles otherwise rebuild on every one of the 10 Hz packets).
  static const int _minNotifyIntervalMs = AppConfig.minNotifyIntervalMs;
  int _lastNotifyMs = 0;
  bool _pendingNotify = false;

  @override
  TelemetryState build() {
    _history = RingBuffer(_historyCapacity);
    _deadReckoningHistory = RingBuffer(_historyCapacity);
    ref.onDispose(() {
      _deadReckoningTicker?.cancel();
      _deadReckoningTicker = null;
    });

    // Auto-ingest the live serial stream for the lifetime of the provider.
    // Frames arrive pre-decoded by the worker's active connector — raw
    // bytes never leave the serial package.
    ref.listen(telemetryStreamProvider, (previous, next) {
      // During a replay the live stream must not mix into the recording.
      if (state.replaying) return;
      next.whenData((frame) => ingest(frame, sourceName: _liveSourceName()));
    });

    // Clear the live flight when the connector changes: framings are
    // connector-specific, so stale frames must not mix with the new ones.
    // Replays override the connector in memory and own the store contents,
    // so they are exempt.
    ref.listen(activeConnectorIdProvider, (previous, next) {
      if (state.replaying) return;
      final prevId = previous?.value ?? defaultConnectorId;
      final nextId = next.value ?? defaultConnectorId;
      if (prevId != nextId) reset();
    });

    // Clear the flight when the connection drops or the port changes.
    ref.listen(serialStatusProvider, (previous, next) {
      next.whenData((status) {
        final name = status.connectedPort ?? '';
        if (state.sourceName.isNotEmpty &&
            name.isNotEmpty &&
            name != state.sourceName &&
            !state.replaying) {
          reset(sourceName: name);
        }
      });
    });

    return TelemetryState(
      history: _history,
      deadReckoningHistory: _deadReckoningHistory,
    );
  }

  String _liveSourceName() {
    final status = ref.read(serialStatusProvider).value;
    return status?.connectedPort ?? 'unknown';
  }

  /// Ingests one internal frame (live or replay). Frames arrive pre-decoded
  /// by the active connector.
  void ingest(TelemetryFrame frame, {String? sourceName}) {
    _history.push(frame);
    // Dead reckoning is a live-only gap filler — replays show the recorded
    // GPS track as-is (no synthetic estimates).
    DeadReckoningPosition? deadReckoning;
    if (!state.replaying) {
      final packet = _lastPacket =
          deadReckoningSampleFromFrame(frame);
      if (frame.gpsHasFix) _lastFixMs = frame.receivedAtMs;
      deadReckoning = projectDeadReckoning(last: packet, elapsedS: 0);
      if (_shouldPushDeadReckoning(frame.receivedAtMs)) {
        _deadReckoningHistory.push(deadReckoning);
        _lastDeadReckoningMs = frame.receivedAtMs;
      }
      _ensureDeadReckoningTicker();
    }

    if (state.replaying) {
      state = _copyWithCurrent(
        latest: frame,
        packetCount: state.packetCount + 1,
        sourceName: sourceName ?? state.sourceName,
        clearDeadReckoning: true,
      );
    } else {
      state = _copyWithCurrent(
        latest: frame,
        deadReckoning: deadReckoning,
        packetCount: state.packetCount + 1,
        sourceName: sourceName ?? state.sourceName,
      );
    }
  }

  /// Bulk-ingests frames with a single state rebuild.
  ///
  /// Replay clocks and seeks push hundreds-to-thousands of frames at once;
  /// ingesting them one by one would notify every watching tile per frame
  /// (26k rebuilds per scrub on a full flight log). Dead reckoning is a
  /// live-only gap filler, so in replay mode it is skipped exactly like in
  /// [ingest]; callers outside replay mode fall back to [ingest] to preserve
  /// the dead reckoning + ticker behaviour.
  void ingestFrames(List<TelemetryFrame> frames, {String? sourceName}) {
    if (frames.isEmpty) return;
    if (!state.replaying) {
      for (final frame in frames) {
        ingest(frame, sourceName: sourceName);
      }
      return;
    }
    TelemetryFrame? last;
    for (final frame in frames) {
      _history.push(frame);
      last = frame;
    }
    state = _copyWithCurrent(
      latest: last ?? state.latest,
      packetCount: state.packetCount + frames.length,
      sourceName: sourceName ?? state.sourceName,
      clearDeadReckoning: true,
    );
  }

  /// Dead reckoning points enter history only while the GPS fix is stale:
  /// with a fresh fix the fix itself is on the GPS track and a projection
  /// would just duplicate it. Once the fix has been silent for over
  /// deadReckoningStaleMs, project from the last packet.
  bool _shouldPushDeadReckoning(int nowMs) {
    final fixMs = _lastFixMs;
    if (fixMs == null || nowMs - fixMs < deadReckoningStaleMs) {
      return false;
    }
    return nowMs - _lastDeadReckoningMs >= deadReckoningUpdateIntervalMs;
  }

  /// Keeps projecting dead reckoning at [deadReckoningUpdateIntervalMs]
  /// even when no packets arrive at all (link loss), from the last packet.
  void _ensureDeadReckoningTicker() {
    if (_deadReckoningTicker != null) return;
    _deadReckoningTicker = Timer.periodic(
        Duration(milliseconds: deadReckoningUpdateIntervalMs), (_) {
      _extrapolateDeadReckoning();
    });
  }

  void _extrapolateDeadReckoning() {
    if (state.replaying || _history.isEmpty) return;
    final latest = _history[0];
    final now = DateTime.now().millisecondsSinceEpoch;
    // Data still flowing — the frame path owns dead reckoning updates.
    if (now - latest.receivedAtMs < deadReckoningStaleMs) return;

    final anchor = _lastPacket;
    if (anchor == null) return;
    final deadReckoning = projectDeadReckoning(
      last: anchor,
      elapsedS: (now - anchor.receivedAtMs) / 1000,
    );
    if (deadReckoning.atMs - _lastDeadReckoningMs <
        deadReckoningUpdateIntervalMs) {
      return;
    }
    _deadReckoningHistory.push(deadReckoning);
    _lastDeadReckoningMs = deadReckoning.atMs;
    _rebuildState();
  }

  /// Clears the flight (new connection, new replay...). Drops history, the
  /// last packet, DR history and ticker; keeps the replaying flag.
  /// Disk untouched. Use [reset] only during migration.
  @override
  void clear() => reset();

  void reset({String? sourceName}) {
    _history.clear();
    _deadReckoningHistory.clear();
    _lastPacket = null;
    _lastFixMs = null;
    _lastDeadReckoningMs = 0;
    _deadReckoningTicker?.cancel();
    _deadReckoningTicker = null;
    _lastNotifyMs = 0;
    state = TelemetryState(
      history: _history,
      deadReckoningHistory: _deadReckoningHistory,
      sourceName: sourceName ?? '',
      replaying: state.replaying,
    );
  }

  /// Marks whether the current data is a replay.
  void setReplaying(bool replaying) {
    if (state.replaying == replaying) return;
    reset(sourceName: replaying ? state.sourceName : '');
    state = _copyWithCurrent(replaying: replaying);
  }

  /// Schedules a throttled state rebuild for high-frequency update paths.
  ///
  /// Used by replay clocks that push hundreds of frames per second: state is
  /// exposed to the UI at most every [_minNotifyIntervalMs] but the internal
  /// history is always up to date.
  void notifyThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyMs >= _minNotifyIntervalMs) {
      _lastNotifyMs = now;
      _pendingNotify = false;
      _rebuildState();
      return;
    }
    if (_pendingNotify) return;
    _pendingNotify = true;
    Future.delayed(Duration(milliseconds: _minNotifyIntervalMs), () {
      if (!_pendingNotify) return;
      _pendingNotify = false;
      _lastNotifyMs = DateTime.now().millisecondsSinceEpoch;
      _rebuildState();
    });
  }

  /// Rebuilds the state object so tiles watching the provider repaint from
  /// the (already mutated) ring buffers. Always republishes the projection
  /// from the last packet: during a link loss the ticker advances it with
  /// no new frames, and without this the exposed position would freeze at
  /// the last packet (indistinguishable from GPS).
  void _rebuildState() {
    final last = _lastPacket;
    state = _copyWithCurrent(
      latest: _history.isEmpty ? null : _history[0],
      deadReckoning: state.replaying || last == null
          ? state.deadReckoning
          : projectDeadReckoning(
              last: last,
              elapsedS:
                  (DateTime.now().millisecondsSinceEpoch - last.receivedAtMs) /
                      1000,
            ),
    );
  }

  /// A new state sharing the live buffers, with the given overrides.
  TelemetryState _copyWithCurrent({
    TelemetryFrame? latest,
    DeadReckoningPosition? deadReckoning,
    bool clearDeadReckoning = false,
    int? packetCount,
    int? errorCount,
    String? sourceName,
    bool? replaying,
  }) {
    return TelemetryState(
      history: _history,
      deadReckoningHistory: _deadReckoningHistory,
      latest: latest ?? state.latest,
      deadReckoning:
          clearDeadReckoning ? null : (deadReckoning ?? state.deadReckoning),
      packetCount: packetCount ?? state.packetCount,
      errorCount: errorCount ?? state.errorCount,
      sourceName: sourceName ?? state.sourceName,
      replaying: replaying ?? state.replaying,
    );
  }
}
