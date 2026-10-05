import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/flight_3d_shell.dart';
import './shared/gpu/flight_gpu_view.dart';
import './shared/orbit_camera.dart';
import './shared/replay_vsync.dart';
import './shared/satellite_terrain_state.dart';

/// 3D flight path over satellite imagery: the same scene and orbit cameras
/// as the plain Flight path tile, but the ground plane is textured with Esri
/// World Imagery around the launch site (the "Google Earth" view). Offline
/// or while tiles load it falls back to the plain ground.
///
/// Imagery covers a fixed 20×20 km around the launch site (nested outer /
/// mid / sharp-pad tiers plus true-scale DEM relief) and is cached per
/// site. Rendered on the GPU (`FlightGpuView`).
class Flight3dSatelliteTile extends ConsumerStatefulWidget {
  const Flight3dSatelliteTile({super.key});

  @override
  ConsumerState<Flight3dSatelliteTile> createState() =>
      _Flight3dSatelliteWidgetState();
}

class _Flight3dSatelliteWidgetState
    extends ConsumerState<Flight3dSatelliteTile>
    with
        SatelliteTerrainState,
        Flight3dShellState,
        SingleTickerProviderStateMixin,
        ReplayVsync {
  @override
  Widget build(BuildContext context) {
    final camera = ref.watch(orbitCameraProvider);
    final replay = ref.watch(replayProvider);
    final resolved =
        resolveTerrainScene(positionMsOverride: replayDisplayMs(replay));
    if (resolved == null) {
      return Center(child: WaitingForData());
    }
    return Flight3dShell(
      mode: mode,
      onMode: setShellMode,
      onZoomBy: zoomBy,
      onResetZoom: resetZoom,
      onOrbit: orbitBy,
      extraOverlays: [
        if (terrainLoading) satelliteLoadingOverlay(),
        if (terrain != null) satelliteAttributionOverlay(),
      ],
      child: FlightGpuView(
        scene: resolved.scene,
        lens: OrbitLens(
          mode: mode,
          azimuthDeg: camera.azimuthDeg,
          elevationDeg: camera.elevationDeg,
          zoom: zoom,
        ),
        terrain: terrain,
        meshes: terrainMeshes,
        anchor: resolved.anchor,
      ),
    );
  }
}
