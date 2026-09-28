import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import './launch_site_store.dart';
import './telemetry_provider.dart';
import '../core/app_config.dart';
import '../core/channel_health.dart';
import '../core/flight_events.dart';
import '../core/path_utils.dart';
import '../foundation/store.dart';
import '../services/recording_repository.dart';
import './telemetry_store.dart';

/// Maps a recording header's launch reference to a display site, or `null`
/// when the header is missing or carries no site.
LaunchSite? launchSiteFromHeader(RecordingHeader? header) {
  final launch = header?.launchRef;
  if (launch == null) return null;
  return LaunchSite(
    name: launch.name,
    latitude: launch.latitude,
    longitude: launch.longitude,
    altitudeMsl: launch.mslM,
  );
}

/// Launch site the visuals (map flag, 3D origin, distances) should anchor
/// to: the replay file's own site while a replay is active (which may be
/// `null` — then no flag is shown rather than a fallback), else the
/// selected site.
final effectiveLaunchSiteProvider = Provider<LaunchSite?>((ref) {
  final replay = ref.watch(replayProvider);
  if (replay.isActive) return replay.launchSite;
  return ref.watch(currentLaunchSiteProvider);
});

/// Replay playback state.
class ReplayState {
  /// Recording currently loaded, or `null` when idle.
  final String? filePath;

  final bool playing;

  /// Playback speed multiplier (0.5, 1, 4, 20).
  final double speed;

  /// Replay clock position relative to recording start (ms of flight time).
  final int positionMs;

  /// Total flight time in the recording (ms), `null` while loading.
  final int? durationMs;

  /// True while a recording is being decoded (play() in flight).
  final bool isLoading;

  /// Set when the recording could not be decoded (unknown format).
  final String? errorMsg;

  /// Every decodable frame of the recording, decoded once up front. Lets
  /// tiles pre-compute whole-flight bounds instead of rescaling while the
  /// replay progresses. Empty outside a replay.
  final List<TelemetryFrame> frames;

  /// Launch site read from the recording header (`null` when the header
  /// carries none). Visuals anchor to this while the replay is active.
  final LaunchSite? launchSite;

  /// Whole-flight channel profile (ours/unknown bytes per 500 ms bin),
  /// rebuilt from the recording's raw chunks so the channel-health monitor
  /// shows the same picture the live view did. Empty outside a replay.
  final List<ChannelBin> channelProfile;

  /// Operator uplink attempts filed in the recording, oldest first.
  /// Empty outside a replay or for command-free files.
  final List<SentCommand> commands;

  /// Stable id of the connector the recording was made with. Playback
  /// auto-selects it so states/commands/events/capabilities resolve with
  /// the recording's own vocabulary.
  final String connectorId;

  /// Display-only smoothing for the 3D views (smoothed trail + stabilized
  /// rotation). The recording bytes and charts are always raw; this only
  /// affects how the 3D tiles paint. Defaults off so replays show the
  /// unfiltered sensor picture; toggle it on to resemble the legacy web
  /// visualizer (which averaged the track).
  final bool smoothingEnabled;

  /// When true, reaching the end of the recording seeks back to the start
  /// and keeps playing instead of pausing. Defaults off.
  final bool loopEnabled;

  const ReplayState({
    this.filePath,
    this.playing = false,
    this.speed = 1,
    this.positionMs = 0,
    this.durationMs,
    this.isLoading = false,
    this.errorMsg,
    this.frames = const [],
    this.launchSite,
    this.channelProfile = const [],
    this.commands = const [],
    this.connectorId = defaultConnectorId,
    this.smoothingEnabled = false,
    this.loopEnabled = false,
  });

  bool get isActive => filePath != null;

  ReplayState copyWith({
    String? filePath,
    bool? playing,
    double? speed,
    int? positionMs,
    int? durationMs,
    bool? isLoading,
    String? errorMsg,
    List<TelemetryFrame>? frames,
    LaunchSite? launchSite,
    List<ChannelBin>? channelProfile,
    List<SentCommand>? commands,
    String? connectorId,
    bool? smoothingEnabled,
    bool? loopEnabled,
  }) => ReplayState(
    filePath: filePath ?? this.filePath,
    playing: playing ?? this.playing,
    speed: speed ?? this.speed,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    isLoading: isLoading ?? this.isLoading,
    errorMsg: errorMsg ?? this.errorMsg,
    frames: frames ?? this.frames,
    launchSite: launchSite ?? this.launchSite,
    channelProfile: channelProfile ?? this.channelProfile,
    commands: commands ?? this.commands,
    connectorId: connectorId ?? this.connectorId,
    smoothingEnabled: smoothingEnabled ?? this.smoothingEnabled,
    loopEnabled: loopEnabled ?? this.loopEnabled,
  );
}

/// Plays a recorded binary telemetry file back through [telemetryStoreProvider]
/// so the whole dashboard works identically on recorded flights.
///
/// The recording's own timestamps drive the clock: a 50 ms ticker ingests all
/// frames whose original arrival time falls under a virtual clock advancing
/// at [ReplayState.speed]× real time.
final replayProvider = NotifierProvider<ReplayController, ReplayState>(
  ReplayController.new,
);

/// Flight milestones detected from the loaded replay's FSM transitions
/// with the recording connector's own event table, in frame order.
///
/// Every marker is one connector-declared transition firing — no
/// data-derived markers: a flight whose firmware skips states (no apogee
/// report, no landed report) truthfully shows only the transitions it
/// made. See `detectFlightEvents`.
///
/// Derived from the pre-decoded frames list identity, so it computes once per
/// loaded recording — not on every playhead tick. Empty outside a replay or
/// when the flight never made the connector's transitions.
final replayFlightEventsProvider = Provider<List<FlightEvent>>((ref) {
  final frames = ref.watch(replayProvider.select((s) => s.frames));
  final connector = ref.watch(activeConnectorProvider);
  return detectFlightEvents(frames, eventDefs: connector.events);
});

/// One filed uplink attempt with its flight-clock position.
class ReplayCommand {
  /// The filed attempt (absolute timestamps).
  final SentCommand command;

  /// Flight-clock position relative to the first frame (ms), clamped at
  /// zero — attempts pre-dating the first decoded frame sit at the start.
  final int positionMs;

  const ReplayCommand({required this.command, required this.positionMs});
}

/// Operator uplink attempts filed in the loaded replay, oldest first, with
/// flight-clock positions resolved against the first frame (mirroring
/// [detectFlightEvents]). Empty outside a replay or for command-free files.
final replayCommandsProvider = Provider<List<ReplayCommand>>((ref) {
  final replay = ref.watch(replayProvider);
  final commands = replay.commands;
  if (commands.isEmpty || replay.frames.isEmpty) return const [];
  final t0 = replay.frames.first.receivedAtMs;
  return [
    for (final command in commands)
      ReplayCommand(
        command: command,
        positionMs: (command.tsMs - t0).clamp(0, 1 << 62),
      ),
  ];
});

class ReplayController extends SessionStore<ReplayState> {
  /// Speed presets offered in the UI.
  static const List<double> speeds = AppConfig.replaySpeeds;

  List<TelemetryFrame> _frames = const [];
  int _index = 0;
  Timer? _ticker;
  int _lastTickMs = 0;

  /// Connector id selected before playback started (in-memory override is
  /// restored on stop so the live choice survives replays).
  String? _savedConnectorId;

  /// Monotonic load generation: each play()/stop() bumps it, and a pending
  /// play() abandons its result when it notices a newer generation. This
  /// closes the stop-during-loading race — the UI disables the close action
  /// while isLoading, but a programmatic stop (or a second play) must not
  /// be resurrected by the stale decode finishing late.
  int _loadGeneration = 0;

  @override
  ReplayState build() {
    ref.onDispose(() {
      _ticker?.cancel();
      _ticker = null;
    });
    return const ReplayState();
  }

  TelemetryStore get _store => ref.read(telemetryStoreProvider.notifier);

  /// Loads [path], decodes every frame up front and starts playback at 1×.
  ///
  /// The recording header's connector is auto-selected (in-memory override,
  /// restored on [stop]) so states/commands/events resolve with the
  /// recording's own vocabulary. The live link is dropped up front — the
  /// replay owns the session — and [stop] stays disconnected, so returning
  /// to live is one tap on Connect.
  Future<void> play(String path) => _play(path, bundled: false);

  /// Loads and plays a read-only bundled asset (`assets/recordings/*.bin`)
  /// without touching disk. The asset key doubles as the replay's
  /// [ReplayState.filePath] identity.
  Future<void> playAsset(String assetKey) => _play(assetKey, bundled: true);

  Future<void> _play(String source, {required bool bundled}) async {
    final initialSmoothing = state.smoothingEnabled;
    final initialLoop = state.loopEnabled;
    final generation = ++_loadGeneration;
    _ticker?.cancel();
    _ticker = null;
    _frames = const [];
    _index = 0;
    _store.setReplaying(false);
    // Publish a loading state immediately so the UI can show a spinner
    // while the (potentially large) source decodes.
    state = ReplayState(
      filePath: source,
      isLoading: true,
      smoothingEnabled: initialSmoothing,
      loopEnabled: initialLoop,
    );

    final loaded = bundled
        ? await RecordingRepository.loadReplayFromAsset(source)
        : await RecordingRepository.loadReplay(source);
    if (generation != _loadGeneration) return;
    if (loaded == null) {
      state = ReplayState(
        filePath: source,
        durationMs: 0,
        errorMsg:
            'Unsupported recording — expected a v3 recording with a header, launch site and known connector.',
        // Keep any toggles made mid-load instead of the entry values.
        smoothingEnabled: state.smoothingEnabled,
        loopEnabled: state.loopEnabled,
      );
      return;
    }

    _frames = loaded.frames;
    _index = 0;
    final frames = loaded.frames;

    // Auto-select the recording's connector for the session (first play
    // remembers the live choice so stop() can restore it; reloads keep the
    // already-saved one).
    _savedConnectorId ??= ref.read(activeConnectorIdProvider).value;
    await ref
        .read(activeConnectorIdProvider.notifier)
        .set(loaded.connector.id, persist: false);

    _store.setReplaying(true);
    // Drop the live link so the replay owns the session (no-op when
    // already offline — which also keeps worker-less tests green).
    if (ref.read(serialStatusProvider).value?.isConnected ?? false) {
      ref.read(serialWorkerProvider).send(const DisconnectCommand());
    }
    final site = launchSiteFromHeader(loaded.header);
    if (generation != _loadGeneration) {
      _store.setReplaying(false);
      return;
    }
    if (site == null) {
      _store.setReplaying(false);
      state = ReplayState(
        filePath: source,
        durationMs: 0,
        errorMsg:
            'Unsupported recording — expected a launch site in the header.',
        smoothingEnabled: state.smoothingEnabled,
        loopEnabled: state.loopEnabled,
      );
      return;
    }
    final channelProfile = loaded.channelProfile;
    if (generation != _loadGeneration) {
      _store.setReplaying(false);
      return;
    }
    state = ReplayState(
      filePath: source,
      playing: true,
      speed: 1,
      positionMs: 0,
      durationMs: _frames.last.receivedAtMs - _frames.first.receivedAtMs,
      frames: frames,
      launchSite: site,
      channelProfile: channelProfile,
      commands: loaded.commands,
      connectorId: loaded.connector.id,
      smoothingEnabled: state.smoothingEnabled,
      loopEnabled: state.loopEnabled,
    );

    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  /// Advances the virtual clock and ingests everything that is due.
  ///
  /// When [ReplayState.loopEnabled] is on, reaching the end seeks back to
  /// the start (carrying the overshoot into the next loop so high speeds
  /// don't lose time) and keeps ticking instead of pausing.
  void _tick() {
    if (_frames.isEmpty) {
      pause();
      return;
    }
    if (_index >= _frames.length) {
      if (state.loopEnabled) {
        _restartLoop();
      } else {
        pause();
      }
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final realDt = now - _lastTickMs;
    _lastTickMs = now;

    final speed = state.speed;
    final t0 = _frames.first.receivedAtMs;
    final clock = state.positionMs + (realDt * speed).round();

    // Batch the due frames into one store rebuild — per-frame ingestion
    // notifies every watching tile.
    final due = <TelemetryFrame>[];
    while (_index < _frames.length) {
      final frame = _frames[_index];
      final rel = frame.receivedAtMs - t0;
      if (rel > clock) break;
      due.add(frame);
      _index++;
    }

    if (due.isNotEmpty) _store.ingestFrames(due, sourceName: _fileName());

    if (_index >= _frames.length && state.loopEnabled) {
      final duration = state.durationMs ?? (_frames.last.receivedAtMs - t0);
      if (duration <= 0) {
        _restartLoop();
        return;
      }
      // Carry the overshoot into the next loop. `clock == duration` wraps
      // to 0; anything beyond keeps its remainder.
      final wrapped = clock % duration;
      _restartLoop(atPositionMs: wrapped);
      return;
    }

    final duration = state.durationMs ?? (_frames.last.receivedAtMs - t0);
    final clampedClock = duration > 0 ? clock.clamp(0, duration) : 0;
    state = state.copyWith(positionMs: clampedClock);

    if (_index >= _frames.length) pause();
  }

  void pause() {
    _ticker?.cancel();
    _ticker = null;
    if (state.playing) {
      state = state.copyWith(playing: false);
    }
  }

  void resume() {
    if (!state.isActive || state.isLoading) return;
    if (_index >= _frames.length) {
      // Restart from the beginning when replaying a finished recording.
      seek(0);
    }
    // Idempotent: a stray live ticker is replaced, a dead one while
    // `playing` is healed — resume always converges on ticking playback.
    _ticker?.cancel();
    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    _ticker = Timer.periodic(
      const Duration(milliseconds: AppConfig.replayTickMs),
      (_) => _tick(),
    );
    if (!state.playing) {
      state = state.copyWith(playing: true);
    }
  }

  /// Single entry point for the play/pause button. Decides by the live timer
  /// rather than the last-published flag alone, so a stale build (or a timer
  /// lost to an exception) can never strand the button: one tap always flips
  /// the actual playback state.
  void toggle() {
    if (state.isLoading) return;
    if ((_ticker?.isActive ?? false) && state.playing) {
      pause();
    } else {
      resume();
    }
  }

  void setSpeed(double speed) {
    if (state.isLoading) return;
    state = state.copyWith(speed: speed);
  }

  /// Current ingestion cursor (frames already in the store). Exposed for
  /// tests pinning the incremental-seek behaviour.
  int get debugIndex => _index;

  /// Toggles the replay-only 3D display smoothing (trail + rotation).
  void setSmoothing(bool enabled) =>
      state = state.copyWith(smoothingEnabled: enabled);

  /// Toggles looping: when on, the end of the recording wraps to the start
  /// instead of pausing. Safe to flip mid-playback — takes effect on the
  /// next tick that reaches the end.
  void setLooping(bool enabled) =>
      state = state.copyWith(loopEnabled: enabled);

  /// Restarts playback from [atPositionMs] (default 0) without pausing.
  /// Exactly one store rebuild: reset + ingest up to the target, mirroring
  /// the backward-jump path in [seek] but keeping the ticker alive and
  /// `playing` true.
  void _restartLoop({int atPositionMs = 0}) {
    if (_frames.isEmpty) {
      pause();
      return;
    }
    final t0 = _frames.first.receivedAtMs;
    var lo = 0;
    var hi = _frames.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_frames[mid].receivedAtMs - t0 > atPositionMs) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    _store.reset(sourceName: _fileName());
    if (lo > 0) {
      _store.ingestFrames(
        _frames.sublist(0, lo),
        sourceName: _fileName(),
      );
    }
    _index = lo;
    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    if (!state.playing) {
      state = state.copyWith(positionMs: atPositionMs, playing: true);
    } else {
      state = state.copyWith(positionMs: atPositionMs);
    }
  }

  /// Jumps to [positionMs].
  ///
  /// Forward jumps ingest only the delta (the store already holds everything
  /// before [_index]); backward jumps reset and replay from the start so the
  /// store's history stays consistent. The target is found by binary search
  /// and ingestion is a single bulk rebuild — scrubbing a 26k-frame flight
  /// no longer replays per-frame state churn from zero on every slider tick.
  void seek(int positionMs) {
    if (state.isLoading || _frames.isEmpty) return;

    final t0 = _frames.first.receivedAtMs;
    var lo = 0;
    var hi = _frames.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_frames[mid].receivedAtMs - t0 > positionMs) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final index = lo;

    if (index > _index) {
      if (_index == 0) _store.reset(sourceName: _fileName());
      _store.ingestFrames(
        _frames.sublist(_index, index),
        sourceName: _fileName(),
      );
    } else if (index < _index) {
      _store.reset(sourceName: _fileName());
      _store.ingestFrames(_frames.sublist(0, index), sourceName: _fileName());
    }

    _index = index;
    state = state.copyWith(positionMs: positionMs);
  }

  /// SessionStore entry: stops playback and returns to live mode.
  @override
  void clear() => stop();

  /// Stops playback and returns the store to live mode. The link stays
  /// disconnected (play() dropped it) — reconnect is one tap on Connect.
  void stop() {
    // Invalidate any in-flight play() so its late async completion is
    // dropped instead of resurrecting a replay the user just closed.
    _loadGeneration++;
    _ticker?.cancel();
    _ticker = null;
    _frames = const [];
    _index = 0;
    _store.setReplaying(false);
    // Restore the live connector choice the replay overrode in play().
    final saved = _savedConnectorId;
    _savedConnectorId = null;
    if (saved != null && isKnownConnectorId(saved)) {
      ref.read(activeConnectorIdProvider.notifier).set(saved, persist: false);
    }
    state = const ReplayState();
  }

  String _fileName() =>
      state.filePath == null ? 'replay' : basename(state.filePath!);
}
