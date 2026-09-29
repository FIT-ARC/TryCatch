import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_provider.dart';
import '../../theme/app_colors.dart';
import '../components/connector_gate.dart';
import './shared/time_series_chart.dart';

/// Vertical (dashed), horizontal and total speed over time (m/s).
/// Series render per connector capabilities: total only when both
/// components are populated, otherwise just the available component(s).
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
  }
}
