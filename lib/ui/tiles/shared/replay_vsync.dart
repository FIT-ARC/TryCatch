import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart' show Ticker, TickerProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/replay_controller.dart';

/// Vsync ticker for the smoothed replay 3D views.
///
/// The replay provider ticks at 20 Hz (ingestion + charts); the 3D tiles
/// need a new scene every display frame while a smoothed replay plays, so
/// they tick at the screen refresh rate via a [Ticker] and extrapolate the
/// display clock with [replayDisplayPositionMs]. Paused, raw and live views
/// never start the ticker — they repaint on provider updates alone.
///
/// Usage: add `SingleTickerProviderStateMixin` + this mixin to the tile
/// state, then `final displayMs = replayDisplayMs(replay)` in `build` and
/// pass it as `positionMsOverride` to the scene/attitude resolvers.
mixin ReplayVsync<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, TickerProvider {
  Ticker? _vsyncTicker;

  @override
  void dispose() {
    _vsyncTicker?.dispose();
    _vsyncTicker = null;
    super.dispose();
  }

  void _ensureVsync(bool shouldTick) {
    if (shouldTick) {
      _vsyncTicker ??= createTicker((_) {
        if (mounted) setState(() {});
      });
      if (!_vsyncTicker!.isActive) _vsyncTicker!.start();
    } else {
      _vsyncTicker?.stop();
    }
  }

  /// Display flight-clock for [replay]: vsync-extrapolated while a smoothed
  /// replay plays, else the provider clock. Starts/stops the ticker as a
  /// side effect — call once per build.
  int replayDisplayMs(ReplayState replay) {
    _ensureVsync(
        replay.isActive && replay.playing && replay.smoothingEnabled);
    if (!replay.playing || !replay.smoothingEnabled) {
      return replay.positionMs;
    }
    return replayDisplayPositionMs(
        replay, DateTime.now().millisecondsSinceEpoch);
  }

  /// Whether the vsync ticker is currently running (tests only).
  @visibleForTesting
  bool get debugVsyncActive => _vsyncTicker?.isActive ?? false;
}
