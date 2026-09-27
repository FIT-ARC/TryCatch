import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/channel_health.dart';
import '../../state/channel_health_provider.dart';
import '../../core/app_config.dart';
import '../../theme/app_colors.dart';
import '../screens/router.dart';

/// Combined link-stats button for the top bar: packet rate + unknown
/// bytes/s in one fixed-width slot.
///
/// Both halves read the shared [RateSeries] (fed from worker LinkStats):
/// packet rate decays to "N s ago" past the 2 s liveness window, unknown
/// rate holds its last value through silence. Disconnected reads as decaying
/// numbers, never blank OFFLINE. Tapping opens Channel health.
class LinkStatsButton extends ConsumerStatefulWidget {
  static const double width = AppConfig.topBarChipWidth;

  const LinkStatsButton({super.key});

  @override
  ConsumerState<LinkStatsButton> createState() => _LinkStatsButtonState();
}

/// Pill color: worse of link liveness and congestion. Silent link reads red;
/// otherwise the congestion verdict color. Neutral before any data.
Color linkStateColor({
  required double unmatchedBps,
  required bool packetsLive,
  required bool hasData,
}) {
  if (!hasData) return AppColors.mutedForeground;
  if (!packetsLive) return AppColors.destructive;
  return switch (verdictFor(unmatchedBps)) {
    ChannelVerdict.clear => AppColors.success,
    ChannelVerdict.activity => AppColors.warning,
    ChannelVerdict.interference => AppColors.destructive,
  };
}

class _LinkStatsButtonState extends ConsumerState<LinkStatsButton> {
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    // 10 Hz repaint: the "N s ago" age reads cleanly while stale.
    _uiTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(channelHealthProvider);
    final series = ref.read(channelHealthProvider.notifier).series;
    final latest = series.latest;

    final unmatched = latest?.unmatchedBps ?? 0.0;
    final hasData = latest != null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final packetsLive =
        latest != null && nowMs - latest.timestampMs <= 2000;
    final Color stateColor = linkStateColor(
      unmatchedBps: unmatched,
      packetsLive: packetsLive,
      hasData: hasData,
    );
    final ratePart = hasData ? series.label(nowMs: nowMs) : 'no data';
    final channelPart =
        latest == null ? '··· B/s' : formatBps(unmatched);
    const tip =
        'Packet rate and unknown traffic on this frequency (ours vs unknown) '
        '— live even while disconnected. Open Channel health.';
    final textColor = hasData
        ? Color.lerp(stateColor, AppColors.foreground, 0.2)!
        : AppColors.mutedForeground;

    return SizedBox(
      width: LinkStatsButton.width,
      height: 32,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Tooltip(
          message: tip,
          mouseCursor: SystemMouseCursors.click,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              mouseCursor: SystemMouseCursors.click,
              onTap: () =>
                  ref.read(appRouterProvider.notifier).go(AppScreen.monitor),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: hasData ? 0.12 : 0.06),
                  borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                  border: Border.all(
                    color: stateColor.withValues(alpha: hasData ? 0.5 : 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Expanded(
                      child: Text(
                        ratePart,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: AppText.mono.copyWith(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Container(
                        width: 1,
                        height: 14,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        channelPart,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: AppText.mono.copyWith(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
