import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/channel_health_provider.dart';
import '../state/replay_controller.dart';
import '../state/telemetry_provider.dart';
import '../state/telemetry_store.dart';

/// Single owner of "Clear buffers". Order: replay first (restores live
/// connector), then telemetry, commands, channel. Toasts excluded (feedback,
/// not flight). Blocked during active replay by callers.
abstract final class FlightReset {
  static void clearFlight(WidgetRef ref) {
    ref.read(replayProvider.notifier).clear();
    ref.read(telemetryStoreProvider.notifier).clear();
    ref.read(commandLogProvider.notifier).clear();
    ref.read(channelHealthProvider.notifier).clear();
  }

  static void clearFlightRef(Ref ref) {
    ref.read(replayProvider.notifier).clear();
    ref.read(telemetryStoreProvider.notifier).clear();
    ref.read(commandLogProvider.notifier).clear();
    ref.read(channelHealthProvider.notifier).clear();
  }
}
