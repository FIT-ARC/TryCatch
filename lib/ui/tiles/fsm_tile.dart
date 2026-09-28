import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../core/flight_states.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';


/// Flight-software state machine view.
///
/// The current state fills the tile — big, centred both ways, time in state
/// under it — with the pipeline grid + progress bar pinned to the bottom.
///
/// A 1 s ticker keeps the time-in-state counting while the link is silent
/// (packet times alone would freeze it the moment telemetry stops).
class FsmTile extends ConsumerStatefulWidget {
  const FsmTile({super.key});

  @override
  ConsumerState<FsmTile> createState() => _FsmWidgetState();
}

class _FsmWidgetState extends ConsumerState<FsmTile> {
  Timer? _ticker;
  Timer? _confirmTimer;

  /// Pending/sent state-request chips, by connector state id (descriptors
  /// are re-created per read, so identity comparison is meaningless).
  int? _pendingStateId;
  int? _sentStateId;

  static const _confirmTimeout = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _confirmTimer?.cancel();
    super.dispose();
  }

  /// Two-click state request, mirroring the control panel: first tap arms
  /// the chip for 3 s, second tap sends the set-state bytes on the wire.
  void _onChipTap(ConnectorFsmState state) {
    final connected =
        ref.read(serialStatusProvider).value?.isConnected ?? false;
    if (!connected) return;
    if (ref.read(replayProvider).isActive) return;

    if (_pendingStateId != state.id) {
      _confirmTimer?.cancel();
      setState(() {
        _pendingStateId = state.id;
        _sentStateId = null;
      });
      _confirmTimer = Timer(_confirmTimeout, () {
        if (mounted) setState(() => _pendingStateId = null);
      });
      return;
    }

    _confirmTimer?.cancel();
    final bytes =
        ref.read(activeConnectorProvider).bytesForState(state.id);
    final ok = bytes != null &&
        ref.read(serialConfigProvider.notifier).sendBytes(
              bytes,
              source: CommandSource.fsm,
            );
    setState(() {
      _pendingStateId = null;
      _sentStateId = ok ? state.id : null;
    });
    if (ok) {
      Timer(const Duration(seconds: 1), () {
        if (mounted && _sentStateId == state.id) {
          setState(() => _sentStateId = null);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(telemetryStoreProvider);
    final latest = state.latest;
    final connector = ref.watch(activeConnectorProvider);

    final unsupported =
        connector.unsupportedPlaceholder(TelemetryField.fsm);
    if (unsupported != null) return unsupported;
    if (latest == null) {
      return Center(child: WaitingForData());
    }

    // Pipeline order comes from the connector (flight order); off-pipeline
    // branches (bench/debug states) show with an empty progress bar in
    // their own row below the pipeline grid. The unknown fallback is never
    // a chip (it can't be requested) — but it still renders as the big
    // readout below when the rocket actually reports it.
    final offerable = [
      for (final s in connector.states)
        if (s.id != connector.unknownStateId) s,
    ];
    final pipeline = [
      for (final s in offerable)
        if (s.pipeline) s,
    ];
    final offPipeline = [
      for (final s in offerable)
        if (!s.pipeline) s,
    ];
    final current = connector.stateForId(latest.fsmStateId);
    final color = AppColors.connectorStateColor(connector, current.id);
    final timeInState = _timeInState(state);
    final currentIndex = pipeline.indexWhere((s) => s.id == current.id);
    final connected =
        ref.watch(serialStatusProvider).value?.isConnected ?? false;
    final replay = ref.watch(replayProvider);
    final replaying = replay.isActive;
    final enabled = connected && !replaying;

    String tooltipFor(ConnectorFsmState s) {
      if (!connected) return 'Connect first';
      if (_pendingStateId == s.id) {
        return 'Tap again to send ${s.label} request';
      }
      return 'Send ${s.label} request to rocket';
    }

    Widget chipFor(ConnectorFsmState s) {
      final tileState = _sentStateId == s.id
          ? _ChipState.sent
          : _pendingStateId == s.id
              ? _ChipState.confirm
              : _ChipState.idle;
      return _StateChip(
        state: s,
        color: AppColors.connectorStateColor(connector, s.id),
        current: s.id == current.id,
        tileState: tileState,
        enabled: enabled,
        replaying: replaying,
        // No tooltips while replaying: the chips are plain state readouts.
        tooltip: replaying ? null : tooltipFor(s),
        onTap: () => _onChipTap(s),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final columns = (constraints.maxWidth / 108).floor().clamp(2, 4);
      // Debug states are normal states — pipeline + off-pipeline chips
      // always show together. Estimate the chip grids' height up front and
      // fall back to the single-line readout when they cannot fit, so
      // nothing overflows.
      final allStates = pipeline.length + offPipeline.length;
      final rows = (allStates / columns).ceil();
      final cellH =
          (constraints.maxWidth - (columns - 1) * 6) / columns / 3.4;
      final chipsH = rows * cellH + (rows - 1) * 6;
      final showProgress = constraints.maxHeight >= 180;
      final progressH = showProgress ? 21.0 : 0.0;
      // Very short tiles drop the chip grids entirely: state + time on one
      // line so nothing can overflow.
      if (constraints.maxHeight.isFinite &&
          constraints.maxHeight < chipsH + progressH + 64) {
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current.label.toUpperCase(),
                  style: AppText.mono.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: color,
                  ),
                ),
                if (timeInState.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Text(
                    timeInState,
                    style: AppText.mono.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mutedForeground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      }
      // Chips tile the available width and size to their content — the grid
      // takes whatever it needs, the big state name gets everything else.
      // Short tiles shed the progress bar first.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The current state fills everything the grid doesn't need,
          // centred both ways.
          Expanded(
            child: Center(
              child: CenteredValue(
                value: current.label.toUpperCase(),
                valueColor: color,
                valueSize: 40,
                letterSpacing: 0.5,
                fit: BoxFit.scaleDown,
                sublabel: timeInState,
                sublabelSize: 12,
                sublabelGap: 6,
              ),
            ),
          ),
          if (showProgress)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _ProgressBar(
                progress: replaying && replay.frames.length >= 2
                    // Replay: fraction through the current state run, from
                    // the full pre-decoded flight — not pipeline stages.
                    ? stateSegmentProgress(
                        replay.frames, replay.positionMs, current.id)
                    : currentIndex < 0
                        ? 0
                        : (currentIndex + 1) / pipeline.length,
                color: color,
              ),
            ),
          // Pipeline grid + off-pipeline row pinned to the bottom, sized
          // to content.
          GridView.count(
            crossAxisCount: columns,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 3.4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              for (final s in pipeline) chipFor(s),
              for (final s in offPipeline) chipFor(s),
            ],
          ),
        ],
      );
    });
  }

  /// How long the rocket has been in the current state, from history. While
  /// the live link is silent the wall clock keeps it ticking past the last
  /// frame; during a replay the playhead rules instead (the wall clock can
  /// be hours off the recording).
  String _timeInState(TelemetryState state) {
    final history = state.history;
    if (history.isEmpty) return '';
    final latest = history[0];
    final since =
        findStateEntryMs(history.toList(growable: false), latest.fsmStateId);
    var endMs = latest.receivedAtMs;
    if (!state.replaying) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - latest.receivedAtMs >
          TelemetryStore.deadReckoningStaleMs) {
        endMs = nowMs;
      }
    }
    return formatTimeInState(
        Duration(milliseconds: endMs - since));
  }
}

enum _ChipState { idle, confirm, sent }

class _StateChip extends StatelessWidget {
  final ConnectorFsmState state;

  /// Theme-aware pastel for [state] (resolved by the parent via
  /// `AppColors.connectorStateColor` — never `Color(state.colorArgb)`
  /// directly, which is the light-mode reference only).
  final Color color;
  final bool current;
  final _ChipState tileState;
  final bool enabled;

  /// `true` while a replay is active: chips render as plain readouts —
  /// no tooltip, no disabled grey.
  final bool replaying;
  final String? tooltip;
  final VoidCallback onTap;

  const _StateChip({
    required this.state,
    required this.color,
    required this.current,
    required this.tileState,
    required this.enabled,
    required this.replaying,
    required this.tooltip,
    required this.onTap,
  });

  /// Pastel label ink: the state hue nudged toward the foreground so
  /// 10 px chip text stays readable on both white and dark cards
  /// (same recipe as [StatusPill]).
  Color _ink(double towardForeground) =>
      Color.lerp(color, AppColors.foreground, towardForeground) ?? color;

  /// Contrasting text for a solid state-color fill: white on dark hues,
  /// near-black on light ones (resolves per active palette, so it holds
  /// in both modes).
  static Color _onSolid(Color bg) =>
      ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
          ? Colors.white
          : const Color(0xFF1B1820);

  @override
  Widget build(BuildContext context) {
    final Color background;
    final Color foreground;
    // Thin outline for the top/right/bottom edges…
    final Color outline;
    final double outlineWidth;
    // …plus a thick solid state-hue strip on the left. Both live in one
    // [BoxDecoration] border so the corners join cleanly instead of the
    // outline stroking over a separate accent bar.
    final Color leftEdge;
    final String label;
    switch (tileState) {
      case _ChipState.idle:
        leftEdge = color;
        if (current) {
          background = color;
          foreground = _onSolid(color);
          outline = color;
          outlineWidth = 1.3;
        } else {
          background = AppColors.card;
          foreground = AppColors.mutedForeground;
          outline = AppColors.border;
          outlineWidth = 1;
        }
        label = state.label.toUpperCase();
      case _ChipState.confirm:
        leftEdge = color;
        background = color.withValues(alpha: 0.18);
        foreground = _ink(0.18);
        outline = color;
        outlineWidth = 1.3;
        label = 'TAP AGAIN?';
      case _ChipState.sent:
        final ok = AppColors.success;
        leftEdge = ok;
        background = ok.withValues(alpha: 0.14);
        foreground =
            Color.lerp(ok, AppColors.foreground, 0.2) ?? ok;
        outline = ok.withValues(alpha: 0.45);
        outlineWidth = 1.3;
        label = 'SENT';
    }

    final faded = !enabled && !replaying && tileState == _ChipState.idle;

    final content = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Opacity(
        // Disabled keeps its real colors at reduced opacity instead of
        // flipping to grey text.
        opacity: faded ? 0.45 : 1.0,
        child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: Ink(
          // Uniform outline (radius-compatible) painted under the splash;
          // the thick left strip below covers its left segment, so the
          // two never stroke over each other at the corners.
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: outline, width: outlineWidth),
          ),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: leftEdge,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(5),
                      bottomLeft: Radius.circular(5),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        style: AppText.mono.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: foreground,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );

    // During replay the chips are inert readouts with no tooltip at all.
    final tip = tooltip;
    if (tip == null) return content;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: content,
    );
  }
}

/// Thin flight-progress bar under the pipeline: fraction of the ordered
/// pipeline reached so far.
class _ProgressBar extends StatelessWidget {
  final double progress;
  final Color color;

  const _ProgressBar({required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Container(
        height: 5,
        decoration: BoxDecoration(
          color: AppColors.muted,
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.centerLeft,
        child: Container(
          width: (constraints.maxWidth * progress.clamp(0.0, 1.0)),
          height: 5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
    });
  }
}
