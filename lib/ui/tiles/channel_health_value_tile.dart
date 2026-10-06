import '../../foundation/time/rate_series.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/channel_health.dart';
import '../../state/channel_health_provider.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './channel_health_tile.dart' show splitChannelBins;

/// Unknown radio traffic on this frequency as a single headline number.
class ChannelHealthValueTile extends ConsumerWidget {
  const ChannelHealthValueTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(channelHealthProvider);
    final series = ref.read(channelHealthProvider.notifier).series;
    final status = ref.watch(serialStatusProvider).value;
    final connected = status?.isConnected ?? false;
    final replay = ref.watch(replayProvider);
    final store = ref.watch(
      telemetryStoreProvider.select((s) => (replaying: s.replaying)),
    );

    final profile = store.replaying && replay.isActive
        ? replay.channelProfile
        : const <ChannelBin>[];
    if (profile.length >= 2) {
      final (played, _) = splitChannelBins(profile, replay.positionMs);
      final cursor = played.isEmpty ? null : played.last;
      final verdict = verdictFor(cursor?.unmatchedBps ?? 0.0);
      return Center(
        child: CenteredValue(
          value: formatBps(cursor?.unmatchedBps ?? 0.0),
          valueColor: _verdictColor(verdict),
          sublabel: '${_verdictLabel(verdict)} · UNKNOWN',
        ),
      );
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
    if (latest == null) {
      return const Center(child: WaitingForData(compact: true));
    }
    final verdict = verdictFor(latest.unmatchedBps);
    return Center(
      child: CenteredValue(
        value: formatBps(latest.unmatchedBps),
        valueColor: _verdictColor(verdict),
        sublabel: '${_verdictLabel(verdict)} · UNKNOWN',
      ),
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
