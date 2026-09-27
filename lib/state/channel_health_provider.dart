import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../foundation/store.dart';
import '../foundation/time/rate_series.dart';
import './telemetry_provider.dart';

/// App-lifetime link-rate history, fed from the worker's link-stats stream.
///
/// One shared [RateSeries] survives widget remounts (edit-mode toggle
/// unmounts tile State; streams deliver once, so per-State trackers lost
/// history). State is a version counter; data lives on the notifier.
class ChannelHealthNotifier extends SessionStore<int> {
  final RateSeries series = RateSeries();

  @override
  int build() {
    ref.listen(linkStatsStreamProvider, (_, next) {
      next.whenData((stats) {
        series.addSnapshot(stats);
        state++;
      });
    });
    return 0;
  }

  @override
  void clear() {
    series.clear();
    state++;
  }
}

final channelHealthProvider =
    NotifierProvider<ChannelHealthNotifier, int>(ChannelHealthNotifier.new);
