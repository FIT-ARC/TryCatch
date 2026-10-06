import '../../state/connector_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';

/// Live speed as a single headline number: total when the connector
/// provides every velocity component, otherwise the available component.
class VelocityValueTile extends ConsumerWidget {
  const VelocityValueTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connector = ref.watch(activeConnectorProvider);
    final hasHorizontal = connector.capabilities.supports(
      TelemetryField.velocityHorizontal,
    );
    final hasVertical = connector.capabilities.supports(
      TelemetryField.velocityVertical,
    );
    if (!hasHorizontal && !hasVertical) {
      return connector.unsupportedPlaceholder(TelemetryField.velocityVertical)!;
    }
    final hasTotal = connector.capabilities.hasFullVelocity;
    final latest = ref.watch(telemetryStoreProvider.select((s) => s.latest));
    if (latest == null) {
      return const Center(child: WaitingForData(compact: true));
    }
    final compact = hasTotal
        ? latest.speedTotal
        : hasVertical
        ? latest.speedVertical
        : latest.speedHorizontal;
    return Center(
      child: CenteredValue(
        value: '${compact.toStringAsFixed(1)} m/s',
        valueColor: AppColors.seriesVelocity,
      ),
    );
  }
}
