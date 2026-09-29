import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart';

/// Vertical (dashed), horizontal and total speed over time (m/s).
/// Series render per connector capabilities: total only when both
/// components are populated, otherwise just the available component(s).
/// Very short tiles show the live readout instead of the graph.
class VelocityChartTile extends ConsumerWidget {
  const VelocityChartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connector = ref.watch(activeConnectorProvider);
    final hasHorizontal = connector.capabilities
        .supports(TelemetryField.velocityHorizontal);
    final hasVertical = connector.capabilities
        .supports(TelemetryField.velocityVertical);
    if (!hasHorizontal && !hasVertical) {
      return connector.unsupportedPlaceholder(
          TelemetryField.velocityVertical)!;
    }
    final hasTotal = connector.capabilities.hasFullVelocity;
    final latest = ref.watch(telemetryStoreProvider).latest;
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxHeight.isFinite &&
          constraints.maxHeight < 90) {
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
      return TimeSeriesChart(
        config: TimeSeriesConfig(
          unit: 'm/s',
          series: [
            if (hasHorizontal)
              SeriesSpec(
                label: 'Horizontal',
                color: AppColors.seriesVelocity,
                value: (f) => f.speedHorizontal,
              ),
            if (hasVertical)
              SeriesSpec(
                label: 'Vertical',
                color: AppColors.seriesVelocityVertical,
                value: (f) => f.speedVertical,
                dashed: true,
              ),
            if (hasTotal)
              SeriesSpec(
                label: 'Total',
                color: AppColors.foreground,
                value: (f) => f.speedTotal,
              ),
          ],
        ),
      );
    });
  }
}
