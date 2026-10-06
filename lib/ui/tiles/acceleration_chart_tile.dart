import '../../state/connector_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../theme/app_colors.dart';
import '../components/connector_gate.dart';
import './shared/time_series_chart.dart';

/// Standard gravity — the chart reads out in G-force.
const double _g0 = 9.80665;

/// Vertical (dashed) and total body acceleration over time (G).
/// Total renders only when the full triple is populated, mirroring the
/// velocity chart rule — every connector provides it today, so this is
/// future-proofing, not a visible change.
class AccelerationChartTile extends ConsumerWidget {
  const AccelerationChartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connector = ref.watch(activeConnectorProvider);
    final unsupported = connector.unsupportedPlaceholder(
      TelemetryField.acceleration,
    );
    if (unsupported != null) return unsupported;
    final hasTotal = connector.capabilities.hasFullAcceleration;
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
  }
}
