import '../../state/connector_provider.dart';

import 'package:dead_reckoning/dead_reckoning.dart' show haversineDistanceM;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../components/connector_gate.dart';
import '../components/position_readout.dart';
import '../components/waiting_for_data.dart';

/// GPS position panel: large coordinates + one line with altitude and drift
/// (horizontal distance from the launch site), a fix-status line below,
/// and copy + QR actions (Google Maps `lat, lon` format).
///
/// GPS-only: the dead-reckoning estimate lives in its own tile
/// (`DeadReckoningTile` in `dead_reckoning_tile.dart`), which only appears
/// on packet loss and is disabled during replays. This tile shows the
/// recorded fix in both live and replay modes.
///
/// Centred in the available space; the whole readout scales down in short
/// tiles instead of clipping.
class StatsTile extends ConsumerWidget {
  const StatsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unsupported = ref
        .watch(activeConnectorProvider)
        .unsupportedPlaceholder(TelemetryField.gpsPosition);
    if (unsupported != null) return unsupported;
    final state = ref.watch(telemetryStoreProvider);
    final replaying = ref.watch(replayProvider.select((s) => s.isActive));
    final latest = state.latest;
    final site = ref.watch(effectiveLaunchSiteProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final drift = site != null && latest.gpsHasFix
        ? haversineDistanceM(
            site.latitude,
            site.longitude,
            latest.latitude,
            latest.longitude,
          )
        : null;

    // Same staleness rule as the store extrapolator and the 3D view: no
    // packets for over a second means the link (not just the fix) is down.
    // GPS-only since the split: the dead-reckoning tile owns the
    // extrapolated readout.
    final linkStale =
        !replaying &&
        DateTime.now().millisecondsSinceEpoch - latest.receivedAtMs >
            TelemetryStore.deadReckoningStaleMs;

    final fix = latest.gpsHasFix ? 'Fix' : 'No fix';

    return PositionReadout(
      coords: latest.gpsHasFix
          ? formatLatLon(latest.latitude, latest.longitude)
          : '—',
      copyText: latest.gpsHasFix
          ? formatLatLonPlain(latest.latitude, latest.longitude)
          : null,
      qrLatitude: latest.gpsHasFix ? latest.latitude : null,
      qrLongitude: latest.gpsHasFix ? latest.longitude : null,
      qrTitle: 'GPS position',
      details: [
        (
          text: 'Altitude ${formatAltitudeM(latest.baroAltitude)}',
          tooltip: null,
        ),
        if (drift != null)
          (
            text: 'Drift ${formatDistanceM(drift)}',
            tooltip: 'Horizontal distance from the launch site',
          ),
      ],
      footer: (text: linkStale ? '$fix · Stale' : fix, tooltip: null),
    );
  }
}
