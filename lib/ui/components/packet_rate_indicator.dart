import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/channel_health_provider.dart';
import '../../theme/app_colors.dart';

/// Fixed-width packet-rate readout for the PACKETS cell, driven by the
/// shared RateSeries: live "X pkt/s" while fresh, "N ago" past 2 s silence.
class PacketRateIndicator extends ConsumerStatefulWidget {
  static const double width = 128;

  const PacketRateIndicator({super.key});

  @override
  ConsumerState<PacketRateIndicator> createState() =>
      _PacketRateIndicatorState();
}

class _PacketRateIndicatorState extends ConsumerState<PacketRateIndicator> {
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
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final timedOut =
        latest == null || nowMs - latest.timestampMs > 2000;
    final label = latest == null ? 'no data yet' : series.label(nowMs: nowMs);

    return SizedBox(
      width: PacketRateIndicator.width,
      height: 32,
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: timedOut ? AppColors.faint : AppColors.pink,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.monoValue.copyWith(
                fontSize: 12.5,
                color: timedOut
                    ? AppColors.mutedForeground
                    : AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
