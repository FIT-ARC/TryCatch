import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../core/channel_health.dart';
import '../../core/format.dart';
import '../../foundation/chart_axis.dart';
import '../../foundation/time/rate_series.dart';
import '../../foundation/time/time_series.dart';
import '../../state/channel_health_provider.dart';
import '../../state/chart_hover_store.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart' show chartTouchData, previewBarAlpha;

/// Tile-friendly channel-health readout: verdict + rolling signal chart.
///
/// The workspace grid wraps every tile in an [AppCard], so this renders
/// no background, no max-width constraint and no nested card.
class ChannelHealthTile extends ConsumerStatefulWidget {
  const ChannelHealthTile({super.key});

  @override
  ConsumerState<ChannelHealthTile> createState() => _ChannelHealthTileState();
}

class _ChannelHealthTileState extends ConsumerState<ChannelHealthTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Repaint on a steady cadence so the live window scrolls even in silence.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Shared history: survives remounts (notably the edit-mode toggle,
    // which swaps wrappers around every tile and recreates tile State).
    ref.watch(channelHealthProvider);
    final series = ref.read(channelHealthProvider.notifier).series;
    final status = ref.watch(serialStatusProvider).value;
    final connected = status?.isConnected ?? false;
    final replay = ref.watch(replayProvider);
    final store = ref.watch(
      telemetryStoreProvider.select((s) => (replaying: s.replaying)),
    );

    // Whole-flight replay view, mirroring TimeSeriesChart.
    final profile = store.replaying && replay.isActive
        ? replay.channelProfile
        : const <ChannelBin>[];
    if (profile.length >= 2) {
      return _TileReplayBody(profile: profile, positionMs: replay.positionMs);
    }

    if (!connected) {
      return const Center(
        child: WaitingForData(
          compact: true,
          hint: 'Connect a port to scan, or replay a flight',
        ),
      );
    }

    final latest = series.latest;
    final matchedBps = latest?.matchedBps ?? 0.0;
    final unmatchedBps = latest?.unmatchedBps ?? 0.0;
    final verdict = verdictFor(unmatchedBps);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TileVerdictRow(
          verdict: verdict,
          matchedBps: matchedBps,
          unmatchedBps: unmatchedBps,
        ),
        const SizedBox(height: 6),
        Expanded(child: _RateChart(series: series)),
      ],
    );
  }
}

/// Splits a replay channel profile at the playhead. The last played bin is
/// carried into the future list so the dimmed segment connects.
(List<ChannelBin> played, List<ChannelBin> future) splitChannelBins(
  List<ChannelBin> profile,
  int positionMs,
) {
  final (played, future) = ListTimeSeries<ChannelBin>(
    (b) => b.startMs,
    profile,
  ).splitAt(positionMs);
  if (played.isNotEmpty && future.isNotEmpty) future.insert(0, played.last);
  return (played, future);
}

/// Compact whole-flight replay body for the tile: verdict row + chart with
/// the played segment at full opacity and the remainder dimmed.
class _TileReplayBody extends StatelessWidget {
  final List<ChannelBin> profile;
  final int positionMs;

  const _TileReplayBody({required this.profile, required this.positionMs});

  @override
  Widget build(BuildContext context) {
    final (played, future) = splitChannelBins(profile, positionMs);
    final cursor = played.isEmpty ? null : played.last;
    final verdict = verdictFor(cursor?.unmatchedBps ?? 0.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TileVerdictRow(
          verdict: verdict,
          matchedBps: cursor?.matchedBps ?? 0.0,
          unmatchedBps: cursor?.unmatchedBps ?? 0.0,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _ReplayChart(
            played: played,
            future: future,
            profile: profile,
            durationMs: null,
            positionMs: positionMs,
          ),
        ),
      ],
    );
  }
}

/// Single-line verdict header for the tile: colored dot + verdict name on
/// the left, ours-vs-unknown rates on the right (ellipsized in narrow
/// tiles).
class _TileVerdictRow extends StatelessWidget {
  final RateVerdict verdict;
  final double matchedBps;
  final double unmatchedBps;

  const _TileVerdictRow({
    required this.verdict,
    required this.matchedBps,
    required this.unmatchedBps,
  });

  @override
  Widget build(BuildContext context) {
    final color = _verdictColor(verdict);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          _verdictLabel(verdict),
          style: AppText.microLabel.copyWith(
            fontSize: 10,
            letterSpacing: 0.8,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${matchedBps.round()} ours · '
            '${unmatchedBps.round()} unknown B/s',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppText.mono.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.mutedForeground,
            ),
          ),
        ),
      ],
    );
  }
}

Color _verdictColor(RateVerdict verdict) => switch (verdict) {
  RateVerdict.clear => AppColors.success,
  RateVerdict.activity => AppColors.warning,
  RateVerdict.interference => AppColors.destructive,
};

String _verdictLabel(RateVerdict verdict) => switch (verdict) {
  RateVerdict.clear => 'CLEAR',
  RateVerdict.activity => 'ACTIVITY',
  RateVerdict.interference => 'INTERFERENCE',
};

/// Channel-health monitor: shows how much radio traffic on our frequency
/// is unknown — does NOT decode as our packets (unknown transmitters, noise).
///
/// Full-screen body behind the Channel health screen (and the replay view).
/// For the dashboard tile see [ChannelHealthTile].
///
/// Live, rates come from cumulative [LinkStats] snapshots emitted by the
/// serial worker (~2 Hz) and plot as a rolling 60 s window. During a replay
/// the tile switches to whole-flight mode like the other charts: the
/// recording's raw chunks (garbage included) were bucketed into
/// [ChannelBin]s at load, so the full flight shows with the played segment
/// at full opacity and the remainder dimmed. Use before launch to check the
/// frequency is free.
class ChannelHealthMonitor extends ConsumerStatefulWidget {
  const ChannelHealthMonitor({super.key});

  @override
  ConsumerState<ChannelHealthMonitor> createState() =>
      _ChannelHealthMonitorState();
}

class _ChannelHealthMonitorState extends ConsumerState<ChannelHealthMonitor> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Repaint on a steady cadence so the live window scrolls even in silence.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Shared history — see the tile above.
    ref.watch(channelHealthProvider);
    final series = ref.read(channelHealthProvider.notifier).series;
    final status = ref.watch(serialStatusProvider).value;
    final connected = status?.isConnected ?? false;
    final replay = ref.watch(replayProvider);
    final store = ref.watch(
      telemetryStoreProvider.select((s) => (replaying: s.replaying)),
    );

    // Whole-flight replay view, mirroring TimeSeriesChart.
    final profile = store.replaying && replay.isActive
        ? replay.channelProfile
        : const <ChannelBin>[];
    if (profile.length >= 2) {
      return _ReplayBody(
        profile: profile,
        positionMs: replay.positionMs,
        durationMs: replay.durationMs,
      );
    }

    if (!connected) {
      return Container(
        color: AppColors.background,
        padding: const EdgeInsets.all(16),
        child: const Center(
          child: WaitingForData(
            hint: 'Connect a port to scan, or replay a flight',
          ),
        ),
      );
    }

    final latest = series.latest;
    final matchedBps = latest?.matchedBps ?? 0.0;
    final unmatchedBps = latest?.unmatchedBps ?? 0.0;
    final verdict = verdictFor(unmatchedBps);

    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _VerdictBanner(
                verdict: verdict,
                matchedBps: matchedBps,
                unmatchedBps: unmatchedBps,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: AppCard(
                  title: 'Signal on this frequency',
                  trailing: _Legend(),
                  fillChild: true,
                  // Display-only plot (axis labels repaint on every tick).
                  child: ExcludeSemantics(child: _RateChart(series: series)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whole-flight replay body: played segment at full opacity, remainder
/// dimmed; verdict and totals follow the playhead.
class _ReplayBody extends StatelessWidget {
  final List<ChannelBin> profile;
  final int positionMs;
  final int? durationMs;

  const _ReplayBody({
    required this.profile,
    required this.positionMs,
    required this.durationMs,
  });

  @override
  Widget build(BuildContext context) {
    final (played, future) = splitChannelBins(profile, positionMs);
    final cursor = played.isEmpty ? null : played.last;
    final verdict = verdictFor(cursor?.unmatchedBps ?? 0.0);

    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _VerdictBanner(
                verdict: verdict,
                matchedBps: cursor?.matchedBps ?? 0.0,
                unmatchedBps: cursor?.unmatchedBps ?? 0.0,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: AppCard(
                  title: 'Signal on this frequency',
                  trailing: _Legend(),
                  fillChild: true,
                  // Display-only plot (axis labels repaint on every tick).
                  child: ExcludeSemantics(
                    child: _ReplayChart(
                      played: played,
                      future: future,
                      profile: profile,
                      durationMs: durationMs,
                      positionMs: positionMs,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  final RateVerdict verdict;
  final double matchedBps;
  final double unmatchedBps;

  const _VerdictBanner({
    required this.verdict,
    required this.matchedBps,
    required this.unmatchedBps,
  });

  @override
  Widget build(BuildContext context) {
    final color = _verdictColor(verdict);
    // The whole box carries the verdict color; just the two numbers inside.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppDimens.radius),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Center(
        child: ExcludeSemantics(
          child: Text(
            '${matchedBps.round()} B/s ours vs '
            '${unmatchedBps.round()} B/s unknown',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppText.monoValue.copyWith(
              fontSize: 16,
              color: Color.lerp(color, AppColors.foreground, 0.2),
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _swatch(AppColors.success, 'OURS'),
        const SizedBox(width: 10),
        _swatch(AppColors.destructive, 'UNKNOWN'),
      ],
    );
  }

  Widget _swatch(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 2.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: AppText.microLabel.copyWith(
            fontSize: 9,
            letterSpacing: 0.8,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _RateChart extends StatelessWidget {
  final RateSeriesView series;

  const _RateChart({required this.series});

  /// Rolling live window (ms) for the tile chart.
  static const _windowMs = 60000;

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final points = series.slice(nowMs - _windowMs, nowMs);

    if (points.length < 2) {
      return const Center(child: WaitingForData(compact: true));
    }

    List<FlSpot> spots(double Function(RateSample) pick) => [
      for (final s in points)
        FlSpot((s.timestampMs - (nowMs - _windowMs)) / 1000, pick(s)),
    ];

    var peak = 1.0;
    for (final s in points) {
      peak = math.max(peak, math.max(s.matchedBps, s.unmatchedBps));
    }
    final maxY = AxisSteps.snappedMax(peak);

    return LineChart(
      _chartData(
        minX: 0,
        maxX: _windowMs / 1000,
        maxY: maxY,
        played: [
          _bar(spots((RateSample s) => s.matchedBps), AppColors.success),
          _bar(
            spots((RateSample s) => s.unmatchedBps),
            AppColors.destructive,
            fill: true,
          ),
        ],
        touchData: chartTouchData(
          entries: [
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
          ],
          unit: 'B/s',
          formatX: (value) => '${(60 - value).toStringAsFixed(0)}s ago',
          formatY: (value) => value.round().toString(),
        ),
        bottomLabel: (value) => '-${(60 - value).toStringAsFixed(0)}s',
      ),
      duration: Duration.zero,
    );
  }
}

/// Whole-flight replay chart: x counts up 0…duration in M:SS, played segment
/// full opacity + remainder dimmed (same language as [TimeSeriesChart]).
/// Hover syncs across every replay chart through the shared hover provider.
class _ReplayChart extends ConsumerWidget {
  final List<ChannelBin> played;
  final List<ChannelBin> future;
  final List<ChannelBin> profile;
  final int? durationMs;
  final int positionMs;

  const _ReplayChart({
    required this.played,
    required this.future,
    required this.profile,
    required this.durationMs,
    required this.positionMs,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profile.length < 2) {
      return const Center(child: WaitingForData(compact: true));
    }

    List<FlSpot> spots(
      List<ChannelBin> bins,
      double Function(ChannelBin) pick,
    ) => [for (final b in bins) FlSpot(b.startMs / 1000, pick(b))];

    var peak = 1.0;
    for (final b in profile) {
      peak = math.max(peak, math.max(b.matchedBps, b.unmatchedBps));
    }
    final maxY = AxisSteps.snappedMax(peak);

    final binMs = profile.length > 1
        ? profile[1].startMs - profile[0].startMs
        : 500;
    final profileEndS = (profile.last.startMs + binMs) / 1000;
    final durationS = (durationMs ?? 0) / 1000;
    // durationMs is null for the tile (playhead-only view): fall back to the
    // profile extent so the axis still spans the whole flight.
    final double maxX = math.max(durationS > 0 ? durationS : 0.0, profileEndS);

    LineChartBarData dimmed(List<FlSpot> s, Color c) =>
        _bar(s, c.withValues(alpha: previewBarAlpha));

    // X axis: clock-friendly M:SS steps so long flights don't pile dozens
    // of overlapping texts (the old 1-2-5 step landed on e.g. 8:20).
    final xStep = replayXInterval(math.max(1.0, maxX));
    final chartMaxX = math.max(1.0, maxX);
    final playheadX = (positionMs / 1000).clamp(0.0, chartMaxX).toDouble();

    // Tooltip legend kept 1:1 with the bars (played + dimmed future +
    // invisible per-series touch bars, in that order) so the touched bar
    // index always resolves its row. Touch runs only on the transparent
    // touch bars over the unified bins (no junction duplicate): one match
    // per series on either side of the playhead — never twins, never
    // sticking. See [chartTouchData].
    final touchBins = [...played, ...future.skip(played.isEmpty ? 0 : 1)];
    List<FlSpot> touchSpots(double Function(ChannelBin) pick) => [
      for (final b in touchBins) FlSpot(b.startMs / 1000, pick(b)),
    ];
    LineChartBarData touchBar(List<FlSpot> s, Color c) =>
        _bar(s, c.withValues(alpha: 0));

    // Shared replay hover (see [chartHoverProvider]): this chart publishes
    // its touched x here and renders the shared x as its own tooltip +
    // markers, so hovering any replay graph lights up the same instant
    // everywhere. Bar indexes are played 0,1 + future 2,3 + touch 4,5.
    final hoverX = ref.watch(chartHoverProvider);
    void onTouch(FlTouchEvent event, LineTouchResponse? response) {
      final spots = response?.lineBarSpots;
      if (!event.isInterestedForInteractions ||
          spots == null ||
          spots.isEmpty) {
        ref.read(chartHoverProvider.notifier).clear();
        return;
      }
      for (final spot in spots) {
        if ((spot.bar.color?.a ?? 1) < 0.05) {
          ref.read(chartHoverProvider.notifier).hover(spot.x);
          return;
        }
      }
      ref.read(chartHoverProvider.notifier).clear();
    }

    var hoverIdx = -1;
    if (hoverX != null && touchBins.isNotEmpty) {
      if (hoverX >= 0 && hoverX <= chartMaxX) {
        hoverIdx = nearestIndexForX([
          for (final b in touchBins) b.startMs / 1000,
        ], hoverX);
      }
    }
    final touchOurs = touchBar(
      touchSpots((b) => b.matchedBps),
      AppColors.success,
    );
    final touchUnknown = touchBar(
      touchSpots((b) => b.unmatchedBps),
      AppColors.destructive,
    );
    final hoverSpots = <LineBarSpot>[];
    if (hoverIdx >= 0) {
      if (hoverIdx < touchOurs.spots.length) {
        hoverSpots.add(LineBarSpot(touchOurs, 4, touchOurs.spots[hoverIdx]));
      }
      if (hoverIdx < touchUnknown.spots.length) {
        hoverSpots.add(
          LineBarSpot(touchUnknown, 5, touchUnknown.spots[hoverIdx]),
        );
      }
    }
    return LineChart(
      _chartData(
        minX: 0,
        maxX: chartMaxX,
        maxY: maxY,
        bottomInterval: xStep,
        playheadX: playheadX,
        played: [
          _bar(spots(played, (b) => b.matchedBps), AppColors.success),
          _bar(
            spots(played, (b) => b.unmatchedBps),
            AppColors.destructive,
            fill: true,
          ),
        ],
        future: [
          dimmed(spots(future, (b) => b.matchedBps), AppColors.success),
          dimmed(spots(future, (b) => b.unmatchedBps), AppColors.destructive),
        ],
        touch: [
          hoverIdx >= 0
              ? touchOurs.copyWith(showingIndicators: [hoverIdx])
              : touchOurs,
          hoverIdx >= 0
              ? touchUnknown.copyWith(showingIndicators: [hoverIdx])
              : touchUnknown,
        ],
        showingTooltipIndicators: hoverSpots.isEmpty
            ? const []
            : [ShowingTooltipIndicators(hoverSpots)],
        touchData: chartTouchData(
          entries: [
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
          ],
          unit: 'B/s',
          formatX: (value) => formatAxisMinSec(value),
          formatY: (value) => value.round().toString(),
          touchBarsOnly: true,
          handleBuiltInTouches: false,
          touchCallback: onTouch,
        ),
        bottomLabel: (value) => formatAxisMinSec(value),
      ),
      duration: Duration.zero,
    );
  }
}

LineChartBarData _bar(List<FlSpot> spots, Color color, {bool fill = false}) =>
    LineChartBarData(
      spots: spots,
      color: color,
      barWidth: 1.6,
      isCurved: false,
      dotData: const FlDotData(show: false),
      belowBarData: fill
          ? BarAreaData(show: true, color: color.withValues(alpha: 0.08))
          : BarAreaData(show: false),
    );

LineChartData _chartData({
  required double minX,
  required double maxX,
  required double maxY,
  required List<LineChartBarData> played,
  List<LineChartBarData>? future,
  List<LineChartBarData> touch = const [],
  required LineTouchData touchData,
  required String Function(double) bottomLabel,
  double? bottomInterval,
  double? playheadX,
  List<ShowingTooltipIndicators> showingTooltipIndicators = const [],
}) {
  final step = AxisSteps.niceStep(maxY / 3);
  final interval = maxY / (maxY / step).round().clamp(2, 6);
  final xInterval = bottomInterval ?? 15;
  return LineChartData(
    minX: minX,
    maxX: maxX,
    minY: 0,
    maxY: maxY,
    extraLinesData: playheadX == null
        ? const ExtraLinesData()
        : ExtraLinesData(
            verticalLines: [
              VerticalLine(
                x: playheadX,
                color: AppColors.mutedForeground,
                strokeWidth: 1.2,
                dashArray: [5, 4],
              ),
            ],
          ),
    gridData: FlGridData(
      show: true,
      drawVerticalLine: true,
      verticalInterval: xInterval,
      horizontalInterval: interval,
      getDrawingHorizontalLine: (value) =>
          FlLine(color: AppColors.border, strokeWidth: 1),
      getDrawingVerticalLine: (value) =>
          FlLine(color: AppColors.border, strokeWidth: 1),
    ),
    borderData: FlBorderData(
      show: true,
      border: Border(
        left: BorderSide(color: AppColors.border),
        bottom: BorderSide(color: AppColors.border),
      ),
    ),
    titlesData: FlTitlesData(
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 48,
          interval: interval,
          getTitlesWidget: (value, meta) => SideTitleWidget(
            meta: meta,
            child: Text(
              AxisSteps.compactLabel(value),
              style: AppText.mono.copyWith(
                fontSize: 9.5,
                color: AppColors.faint,
              ),
            ),
          ),
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 18,
          interval: xInterval,
          getTitlesWidget: (value, meta) => SideTitleWidget(
            meta: meta,
            child: Text(
              bottomLabel(value),
              style: AppText.mono.copyWith(
                fontSize: 9.5,
                color: AppColors.faint,
              ),
            ),
          ),
        ),
      ),
    ),
    lineTouchData: touchData,
    lineBarsData: [...played, ...?future, ...touch],
    showingTooltipIndicators: showingTooltipIndicators,
  );
}
