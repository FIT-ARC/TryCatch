import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';

/// Peak barometric altitude (m AGL) reached in the current session.
///
/// Split out of the old stats panel so the headline number can live in its
/// own tile; the GPS position and dead-reckoning tiles keep the live
/// position readouts.
/// Just the peak — no live value.
class MaxAltitudeTile extends ConsumerWidget {
  const MaxAltitudeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.baroAltitude);
    if (unsupported != null) return unsupported;
    final state = ref.watch(telemetryStoreProvider);
    if (state.history.isEmpty) {
      return const Center(child: WaitingForData());
    }
    final maxAlt = state.maxAltitude;

    // No headline label — the card header already says what this is.
    // CenteredValue scale-downs in short tiles, so no extra breakpoint.
    return Center(
      child: CenteredValue(
        value: formatAltitudeM(maxAlt),
        valueColor: AppColors.seriesAltitude,
      ),
    );
  }
}
