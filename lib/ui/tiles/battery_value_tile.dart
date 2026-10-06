import '../../state/connector_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';

/// Live battery voltage as a single headline number.
class BatteryValueTile extends ConsumerWidget {
  const BatteryValueTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.battery);
    if (unsupported != null) return unsupported;
    final latest = ref.watch(telemetryStoreProvider.select((s) => s.latest));
    if (latest == null) {
      return const Center(child: WaitingForData(compact: true));
    }
    return Center(
      child: CenteredValue(
        value: '${latest.batteryVoltage.toStringAsFixed(2)} V',
        valueColor: AppColors.seriesBattery,
      ),
    );
  }
}
