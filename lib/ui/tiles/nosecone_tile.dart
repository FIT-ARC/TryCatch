import '../../state/connector_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/connector_gate.dart';
import '../components/waiting_for_data.dart';

/// Nose-cone lock state in the centred tile language: big padlock icon +
/// label, centred both ways. Locked green, unlocked red.
///
/// Locked = the cone is on the airframe (the active connector's
/// `hasNosecone`: idle/armed/ascent/debug-locked on MOCK). Unlocked = the
/// cone is off, so the 3D views hide it. The 3D canopy itself renders on
/// parachute only (`showsParachute`).
class NoseconeTile extends ConsumerWidget {
  const NoseconeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connector = ref.watch(activeConnectorProvider);
    final unsupported = connector.unsupportedPlaceholder(TelemetryField.fsm);
    if (unsupported != null) return unsupported;
    final latest = ref.watch(telemetryStoreProvider.select((s) => s.latest));
    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final locked = connector.stateForId(latest.fsmStateId).hasNosecone;
    final (Color color, IconData icon, String label) = locked
        ? (AppColors.success, Icons.lock, 'LOCKED')
        : (AppColors.destructive, Icons.lock_open, 'UNLOCKED');

    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Very short tiles drop the label — the icon alone reads clearly.
          if (constraints.maxHeight.isFinite && constraints.maxHeight < 80) {
            return Icon(icon, size: 30, color: color);
          }
          // Small tiles shrink the icon instead of clipping.
          final iconSize = constraints.maxHeight < 90 ? 26.0 : 44.0;
          return CenteredValue(
            icon: icon,
            iconSize: iconSize,
            value: label,
            valueColor: color,
            valueSize: 11,
            microValue: true,
          );
        },
      ),
    );
  }
}
