import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/path_utils.dart';
import '../../state/replay_controller.dart';
import '../../theme/app_colors.dart';
import '../../core/flight_events.dart';
import '../../core/format.dart';
import './flight_event_style.dart';

/// Playback controls shown in the top bar while a replay is active.
///
/// Replaces the serial connection and recording groups — the app is replaying
/// recorded telemetry, not listening to the radio. File name, transport,
/// seek and speed. The constant "Back to live" close action lives in the
/// top-bar menu slot (see TopBar), in the exact spot the hamburger button
/// occupies when live.
class PlaybackBar extends ConsumerWidget {
  const PlaybackBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Select only the fields the clock text + slider need so the outer row
    // doesn't rebuild on every 50 ms positionMs tick. The buttons are leaf
    // consumers that each subscribe to exactly the fields they render —
    // a pure rebuild-avoidance optimization.
    final duration = ref.watch(
      replayProvider.select((s) => s.durationMs ?? 0),
    );
    final position = ref.watch(
      replayProvider.select((s) => s.positionMs),
    ).clamp(0, duration);
    final isLoading = ref.watch(
      replayProvider.select((s) => s.isLoading),
    );
    final speed = ref.watch(replayProvider.select((s) => s.speed));
    final controller = ref.read(replayProvider.notifier);

    return Row(
      children: [
        const _ReplayBadge(),
        // Isolated leaf consumer: rebuilds only when playing/finished/loading
        // changes — not on every positionMs tick.
        const _PlayPauseButton(),
        // Fixed-width clock: position pads to the duration's minute width
        // ("7:42 / 17:29") so scrubbing never shifts siblings as digits grow.
        _ClockText(position: position, duration: duration),
        const SizedBox(width: 4),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _ReplayTimeline(duration: duration, position: position),
          ),
        ),
        const SizedBox(width: 4),
        _SpeedMenu(
          speed: speed,
          onSelect: controller.setSpeed,
          enabled: !isLoading,
        ),
        // Isolated leaf consumer: rebuilds only when smoothing/loading
        // changes — not on every positionMs tick.
        const _SmoothingButton(),
        // Isolated leaf consumer: rebuilds only when loop/loading changes.
        const _LoopButton(),
      ],
    );
  }
}

/// Fixed-width clock readout: the position pads with leading zeros to the
/// duration's minute width, so the row never shifts while scrubbing.
class _ClockText extends StatelessWidget {
  final int position;
  final int duration;

  const _ClockText({required this.position, required this.duration});

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    String clock(int ms) {
      final totalS = ms ~/ 1000;
      return '${two(totalS ~/ 60)}:${two(totalS % 60)}';
    }

    return Text(
      '${clock(position)} / ${clock(duration)}',
      maxLines: 1,
      style: AppText.mono.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: AppColors.mutedForeground,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Play / Pause / Replay-from-start transport button.
///
/// Leaf consumer on `{isLoading, playing, positionMs, durationMs}` — the
/// fields that determine which icon and tooltip to show. Kept out of the
/// outer [PlaybackBar] build so its [Tooltip] is only re-created when those
/// fields change, not on every 50 ms ticker tick.
class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));
    final playing = ref.watch(replayProvider.select((s) => s.playing));
    final positionMs = ref.watch(replayProvider.select((s) => s.positionMs));
    final durationMs = ref.watch(replayProvider.select((s) => s.durationMs));
    final duration = durationMs ?? 0;
    // At the end the transport becomes a restart affordance — toggle()
    // seeks back to 0 when the recording is finished.
    final finished = !playing && duration > 0 && positionMs >= duration;
    final controller = ref.read(replayProvider.notifier);

    return IconButton(
      tooltip: finished
          ? 'Replay from the start (Space)'
          : (playing ? 'Pause (Space)' : 'Play (Space)'),
      // toggle() keys off the live ticker, not just the last-published
      // flag, so the button can never desync from actual playback.
      onPressed: isLoading ? null : controller.toggle,
      icon: Icon(
        finished
            ? Icons.replay
            : (playing ? Icons.pause : Icons.play_arrow),
        size: 20,
        color: AppColors.pinkDeep,
      ),
    );
  }
}

/// Replay-only 3D display smoothing toggle.
///
/// Leaf consumer on `{isLoading, smoothingEnabled}` — rebuilds only when
/// those fields change, not on every 50 ms positionMs tick. See
/// [_PlayPauseButton] for the full rationale.
class _SmoothingButton extends ConsumerWidget {
  const _SmoothingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));
    final smoothingEnabled = ref.watch(
      replayProvider.select((s) => s.smoothingEnabled),
    );
    final controller = ref.read(replayProvider.notifier);

    // The "Back to live" close action lives in the top-bar menu slot (same
    // spot/size as the hamburger button), not in this row.
    return IconButton(
      tooltip: smoothingEnabled
          ? 'Display smoothing on (3D trail + rotation) — tap for raw'
          : 'Display smoothing off — tap to smooth the 3D display',
      onPressed: isLoading
          ? null
          : () => controller.setSmoothing(!smoothingEnabled),
      icon: Icon(
        Icons.blur_on,
        size: 20,
        color: smoothingEnabled
            ? AppColors.pinkDeep
            : AppColors.mutedForeground,
      ),
    );
  }
}

/// Loop toggle: when on, the end of the recording wraps to the start
/// instead of pausing.
///
/// Leaf consumer on `{isLoading, loopEnabled}` — rebuilds only when those
/// fields change, not on every 50 ms positionMs tick. See
/// [_PlayPauseButton] for the full rationale.
class _LoopButton extends ConsumerWidget {
  const _LoopButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));
    final loopEnabled = ref.watch(
      replayProvider.select((s) => s.loopEnabled),
    );
    final controller = ref.read(replayProvider.notifier);

    return IconButton(
      tooltip: loopEnabled
          ? 'Loop on — replay restarts at the end (tap for play-once)'
          : 'Loop off — tap to replay in a loop',
      onPressed:
          isLoading ? null : () => controller.setLooping(!loopEnabled),
      icon: Icon(
        Icons.repeat,
        size: 20,
        color:
            loopEnabled ? AppColors.pinkDeep : AppColors.mutedForeground,
      ),
    );
  }
}

/// Scrub slider with flight-milestone markers overlaid on the track.
///
/// Markers come from [replayFlightEventsProvider] (one per nominal FSM
/// transition in the loaded recording — zero, one or several of each type).
/// Each marker seeks the replay to its flight-clock position when tapped.
/// The marker buttons themselves only rebuild when the loaded flight changes;
/// the played/upcoming dimming inside each dot is a leaf consumer on the
/// playhead, so tooltips aren't rebuilt at the ~20 Hz repaint rate.
///
/// Marker dots share the slider's exact value→pixel mapping (see
/// [_timelineThumbTravel]), and markers that would paint on top of each
/// other are spread into alternating lanes above/below the track with a tick
/// back to the true position ([placeFlightEvents]).
class _ReplayTimeline extends ConsumerWidget {
  final int duration;
  final int position;

  const _ReplayTimeline({required this.duration, required this.position});

  /// Pinned slider geometry. These are the Material 3 defaults, so the
  /// slider looks exactly as before — but pinning them fixes the thumb
  /// travel by construction: with `padding: null` the track is inset by
  /// `max(overlay, thumb) / 2` on each side
  /// (`BaseSliderTrackShape.getPreferredRect`), i.e. 24 px from the r24
  /// overlay, and the thumb center runs from 24 to `width - 24`.
  /// [_timelineInsetPx] mirrors that inset so markers sit on the thumb path.
  static const _thumbShape = RoundSliderThumbShape();
  static const _overlayShape = RoundSliderOverlayShape();

  static double _timelineInsetPx() {
    final thumb = _thumbShape.getPreferredSize(true, false).width / 2;
    final overlay = _overlayShape.getPreferredSize(true, false).width / 2;
    return math.max(thumb, overlay);
  }

  /// Hit target for one marker. Kept tight around the dot on purpose:
  /// stacked lanes sit 16 px apart, so roomy targets would overlap and a
  /// tap would fire two seeks.
  static const double _hitSize = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(replayProvider.notifier);
    final events = ref.watch(replayFlightEventsProvider);
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final inset = _timelineInsetPx();
        final placements = placeFlightEvents(
          events,
          duration,
          widthPx: width,
          trackLeftPx: inset,
          trackWidthPx: math.max(0.0, width - 2 * inset),
        );
        // The slider track is vertically centered in its box and the slider
        // is the size-determining child of this stack, so the track center
        // is the stack's vertical midpoint.
        final height = constraints.maxHeight;
        final centerY = height.isFinite ? height / 2 : null;
        return Stack(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: _thumbShape,
                overlayShape: _overlayShape,
                padding: null,
              ),
              child: Slider(
                value: duration == 0 ? 0 : position / duration,
                onChanged: duration == 0 || isLoading
                    ? null
                    : (v) => controller.seek((v * duration).round()),
                // Grabbing the timeline pauses so the ticker stops fighting
                // the scrub; playback stays paused until the user resumes.
                onChangeStart: duration == 0 || isLoading
                    ? null
                    : (_) => controller.pause(),
              ),
            ),
            if (placements.isNotEmpty && centerY != null)
              Positioned.fill(
                // Unclipped: edge markers render fully, exactly like the
                // slider thumb overflowing at the extremes — and, more
                // importantly, dots are never shifted away from their true
                // position to fit an arbitrary box.
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final p in placements) ...[
                      if (p.dyPx != 0)
                        Positioned(
                          left: p.xPx - 1,
                          width: 2,
                          top: p.dyPx < 0
                              ? centerY + p.dyPx + flightEventDotDiameterPx / 2
                              : centerY,
                          height: p.dyPx.abs() - flightEventDotDiameterPx / 2,
                          child: IgnorePointer(
                            child: _EventTick(event: p.event),
                          ),
                        ),
                      Positioned(
                        left: p.xPx - _hitSize / 2,
                        top: centerY + p.dyPx - _hitSize / 2,
                        width: _hitSize,
                        height: _hitSize,
                        child: IconButton(
                          tooltip:
                              '${p.event.label} at ${formatMinSec(p.event.positionMs)} — tap to seek',
                          onPressed: isLoading
                              ? null
                              : () => controller.seek(p.event.positionMs),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(_hitSize, _hitSize),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: EdgeInsets.zero,
                          ),
                          icon: _EventDot(event: p.event),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Thin connector from an off-track marker dot back to its exact position
/// on the track. Purely visual (the button does the seeking) and static —
/// no playhead subscription, no rebuild churn.
class _EventTick extends StatelessWidget {
  final FlightEvent event;

  const _EventTick({required this.event});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: flightEventStyleOf(event.type).color().withValues(alpha: 0.55),
    );
  }
}

/// Marker dot for one flight event, dimmed while still ahead of the
/// playhead.
///
/// Leaf consumer on the playhead only — the parent tooltip/button (built once
/// per loaded flight) never rebuilds at the ticker rate.
class _EventDot extends ConsumerWidget {
  final FlightEvent event;

  const _EventDot({required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positionMs = ref.watch(replayProvider.select((s) => s.positionMs));
    return FlightEventDot(
      type: event.type,
      dimmed: positionMs < event.positionMs,
    );
  }
}

/// Replay filename + tooltip, watching the file path only.
///
/// The playhead rebuilds this bar ~20 Hz while playing; keeping the filename
/// Tooltip out of those rebuilds avoids re-creating it at ticker rate.
class _ReplayBadge extends ConsumerWidget {
  const _ReplayBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fileName = ref.watch(
      replayProvider.select(
        (s) => s.filePath == null ? 'recording' : basename(s.filePath!),
      ),
    );
    return Tooltip(
      message: 'Replaying $fileName — the radio is not being listened to',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.mutedForeground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Playback-speed picker: a compact popup instead of a row of chips.
class _SpeedMenu extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onSelect;
  final bool enabled;

  const _SpeedMenu({
    required this.speed,
    required this.onSelect,
    this.enabled = true,
  });

  static String _label(double s) =>
      s < 1 ? '${s.toStringAsFixed(1)}×' : '${s.toInt()}×';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: speed,
      enabled: enabled,
      tooltip: enabled ? 'Playback speed' : 'Loading flight…',
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final s in ReplayController.speeds)
          PopupMenuItem(
            value: s,
            child: Text(
              _label(s),
              style: TextStyle(
                fontFamily: AppText.monoFamily,
                fontWeight: FontWeight.w700,
                color: s == speed ? AppColors.pinkDeep : AppColors.foreground,
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          border: Border.all(color: AppColors.strongBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(speed),
              style: AppText.mono.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: AppColors.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}
