import '../../state/connector_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';

/// Live barometric altitude as a single headline number.
class AltitudeValueTile extends ConsumerWidget {
  const AltitudeValueTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.baroAltitude);
    if (unsupported != null) return unsupported;
    final latest = ref.watch(telemetryStoreProvider.select((s) => s.latest));
    if (latest == null) {
      return const Center(child: WaitingForData(compact: true));
    }
    return Center(
      child: CenteredValue(
        value: formatAltitudeM(latest.baroAltitude),
        valueColor: AppColors.seriesAltitude,
      ),
    );
  }
}
