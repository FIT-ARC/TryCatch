import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_provider.dart';
import '../../theme/app_colors.dart';
import '../components/connector_gate.dart';
import './shared/time_series_chart.dart';

/// Barometric altitude over time (m AGL) — the headline series, team pink.
class AltitudeChartTile extends ConsumerWidget {
  const AltitudeChartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.baroAltitude);
    if (unsupported != null) return unsupported;
    return TimeSeriesChart(
      config: TimeSeriesConfig(
        unit: 'm',
        // Single line — no legend needed.
        showLegend: false,
        series: [
          SeriesSpec(
            label: 'Altitude',
            color: AppColors.seriesAltitude,
            value: (f) => f.baroAltitude,
          ),
        ],
      ),
    );
  }
}
