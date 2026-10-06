import '../../state/connector_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';
import './hall_sensor_tile.dart' show HallSensorTile;

/// Live breakaway-wire hall sensor reading as a single headline number:
/// green intact, red broken at [HallSensorTile.triggeredThreshold].
class HallSensorValueTile extends ConsumerWidget {
  const HallSensorValueTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.hall);
    if (unsupported != null) return unsupported;
    final latest = ref.watch(telemetryStoreProvider.select((s) => s.latest));
    if (latest == null) {
      return const Center(child: WaitingForData(compact: true));
    }
    final raw = latest.hallRaw;
    final triggered = raw >= HallSensorTile.triggeredThreshold;
    final color = triggered ? AppColors.destructive : AppColors.success;
    return Center(
      child: CenteredValue(value: '$raw', valueColor: color),
    );
  }
}
