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

/// Standard gravity — the chart reads out in G-force.
const double _g0 = 9.80665;

/// Vertical (dashed) and total body acceleration over time (G).
/// Total renders only when the full triple is populated, mirroring the
/// velocity chart rule — every connector provides it today, so this is
/// future-proofing, not a visible change.
/// Very short tiles show the live readout instead of the graph.
class AccelerationChartTile extends ConsumerWidget {
  const AccelerationChartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connector = ref.watch(activeConnectorProvider);
    final unsupported =
        connector.unsupportedPlaceholder(TelemetryField.acceleration);
    if (unsupported != null) return unsupported;
    final hasTotal = connector.capabilities.hasFullAcceleration;
    final latest = ref.watch(telemetryStoreProvider).latest;
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxHeight.isFinite &&
          constraints.maxHeight < 90) {
        if (latest == null) {
          return const Center(child: WaitingForData(compact: true));
        }
        final compact =
            hasTotal ? latest.accelTotal : latest.accelVertical;
        return Center(
          child: CenteredValue(
            value: '${(compact / _g0).toStringAsFixed(1)} G',
            valueColor: AppColors.seriesAccel,
          ),
        );
      }
      return TimeSeriesChart(
        config: TimeSeriesConfig(
          unit: 'G',
          series: [
            SeriesSpec(
              label: 'Vertical',
              color: AppColors.seriesAccel,
              value: (f) => f.accelVertical / _g0,
              dashed: true,
            ),
            if (hasTotal)
              SeriesSpec(
                label: 'Total',
                color: AppColors.foreground,
                value: (f) => f.accelTotal / _g0,
              ),
          ],
        ),
      );
    });
  }
}
