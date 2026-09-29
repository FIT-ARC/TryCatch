import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';

/// Standard gravity — the readout is in G-force.
const double _g0 = 9.80665;

/// Live acceleration as a single headline number: total when the full
/// triple is populated, otherwise the vertical component.
class AccelerationValueTile extends ConsumerWidget {
  const AccelerationValueTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connector = ref.watch(activeConnectorProvider);
    final unsupported =
        connector.unsupportedPlaceholder(TelemetryField.acceleration);
    if (unsupported != null) return unsupported;
    final hasTotal = connector.capabilities.hasFullAcceleration;
    final latest = ref.watch(telemetryStoreProvider).latest;
    if (latest == null) {
      return const Center(child: WaitingForData(compact: true));
    }
    final compact = hasTotal ? latest.accelTotal : latest.accelVertical;
    return Center(
      child: CenteredValue(
        value: '${(compact / _g0).toStringAsFixed(1)} G',
        valueColor: AppColors.seriesAccel,
      ),
    );
  }
}
