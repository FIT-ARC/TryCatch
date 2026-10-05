import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/flight_3d_shell.dart';
import './shared/gpu/flight_gpu_view.dart';
import './shared/orbit_camera.dart';
import './shared/replay_vsync.dart';

/// 3D flight path view: the rocket flies through a metric world (east/up/
/// south metres relative to the launch site), leaving its trail behind it.
/// The launch site is marked with a flag on a gridded ground plane, and the
/// camera can chase the rocket, orbit the whole field, or orbit freely.
///
/// Positions come from GPS fixes; a stale GPS estimate is shown as a single
/// violet dead-reckoning point (never a trail). The rocket stands on its tail
/// at the reported position. Rendered on the GPU (`FlightGpuView`); scene,
/// cameras and lenses are shared with the satellite views via
/// `flight_3d_common.dart`.
class Flight3dTile extends ConsumerStatefulWidget {
  const Flight3dTile({super.key});

  @override
  ConsumerState<Flight3dTile> createState() => _Flight3dWidgetState();
}

class _Flight3dWidgetState extends ConsumerState<Flight3dTile>
    with Flight3dShellState, SingleTickerProviderStateMixin, ReplayVsync {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(telemetryStoreProvider);
    final site = ref.watch(effectiveLaunchSiteProvider);
    final replay = ref.watch(replayProvider);
    final latest = state.latest;
    final camera = ref.watch(orbitCameraProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final connector = ref.watch(activeConnectorProvider);
    final scene = resolveFlightScene(
      state: state,
      site: site,
      replay: replay,
      connector: connector,
      positionMsOverride: replayDisplayMs(replay),
    );
    if (scene == null) {
      // Frames are arriving but no position anchor (no fix, no site) yet.
      return Center(child: WaitingForData());
    }

    return Flight3dShell(
      mode: mode,
      onMode: setShellMode,
      onZoomBy: zoomBy,
      onResetZoom: resetZoom,
      onOrbit: orbitBy,
      child: FlightGpuView(
        scene: scene,
        lens: OrbitLens(
          mode: mode,
          azimuthDeg: camera.azimuthDeg,
          elevationDeg: camera.elevationDeg,
          zoom: zoom,
        ),
      ),
    );
  }
}
