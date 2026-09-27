import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/channel_health.dart';
import '../foundation/store.dart';
import '../foundation/time/rate_series.dart';
import './telemetry_provider.dart';

/// App-lifetime link-rate history, fed from the worker's link-stats stream.
///
/// One shared series survives widget remounts (edit-mode toggle unmounts
/// tile State; streams deliver once, so per-State trackers lost history).
/// State is a version counter; data lives on the notifier.
///
/// Migration: [series] is the unified model (see foundation/time/).
/// [tracker] is the legacy view kept until tiles migrate; both are fed
/// from the same snapshots and cleared together.
class ChannelHealthNotifier extends SessionStore<int> {
  final ChannelHealthTracker tracker = ChannelHealthTracker();
  final RateSeries series = RateSeries();

  @override
  int build() {
    ref.listen(linkStatsStreamProvider, (_, next) {
      next.whenData((stats) {
        tracker.addSnapshot(stats);
        series.addSnapshot(stats);
        state++;
      });
    });
    return 0;
  }

  @override
  void clear() {
    tracker.reset();
    series.clear();
    state++;
  }
}

final channelHealthProvider =
    NotifierProvider<ChannelHealthNotifier, int>(ChannelHealthNotifier.new);
