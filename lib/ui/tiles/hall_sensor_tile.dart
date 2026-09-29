import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/connector_gate.dart';
import './shared/time_series_chart.dart';

/// Breakaway-wire hall sensor over time: the line color carries the state
/// (green intact, red broken at [triggeredThreshold]).
class HallSensorTile extends ConsumerWidget {
  /// Raw value at or above which the wire counts as broken.
  static const double triggeredThreshold = 2700;

  const HallSensorTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.hall);
    if (unsupported != null) return unsupported;
    final latest = ref.watch(telemetryStoreProvider).latest;

    final raw = latest?.hallRaw ?? 0;
    final triggered = raw >= triggeredThreshold;
    final color = triggered ? AppColors.destructive : AppColors.success;

    return TimeSeriesChart(
      config: TimeSeriesConfig(
        unit: '',
        showLegend: false,
        series: [
          SeriesSpec(
            label: 'Hall',
            color: color,
            value: (f) => f.hallRaw.toDouble(),
          ),
        ],
      ),
    );
  }
}
