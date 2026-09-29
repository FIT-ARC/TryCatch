import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/flight_3d_shell.dart';
import './shared/gpu/flight_gpu_view.dart';
import './shared/satellite_terrain_state.dart';

/// Onboard camera view: the rocket's-eye strap-down lens over the same
/// satellite terrain as the 3D Flight tile. The lens rides at the airframe,
/// looking out its side with the nose up, so the horizon follows the full
/// attitude. Dragging spins the gaze around the rocket's long axis;
/// double-tap recenters it. The lens is fixed — no zoom, no camera modes.
///
/// Rendered on the GPU (`FlightGpuView` with the onboard lens).
class OnboardCameraTile extends ConsumerStatefulWidget {
  const OnboardCameraTile({super.key});

  @override
  ConsumerState<OnboardCameraTile> createState() => _OnboardCameraTileState();
}

class _OnboardCameraTileState extends ConsumerState<OnboardCameraTile>
    with SatelliteTerrainState {
  /// Spin (degrees) around the rocket's long axis from the pure side view.
  double _spinDeg = 0.0;

  /// Per-tile easing for the strap-down attitude (jitter melts, jumps snap).
  final OnboardAttitudeSmoother _smoother = OnboardAttitudeSmoother();

  @override
  Widget build(BuildContext context) {
    final resolved = resolveTerrainScene();
    if (resolved == null) {
      return Center(child: WaitingForData());
    }
    return Flight3dShell(
      modes: const [],
      onZoomBy: (_) {},
      onResetZoom: () => setState(() => _spinDeg = 0.0),
      onOrbit: (delta) =>
          setState(() => _spinDeg = spinAfterDrag(_spinDeg, delta.dx)),
      extraOverlays: [if (terrain != null) satelliteAttributionOverlay()],
      child: FlightGpuView(
        scene: _smoother.apply(resolved.scene),
        lens: OnboardLens(spinDeg: _spinDeg),
        terrain: terrain,
        meshes: terrainMeshes,
        anchor: resolved.anchor,
        showAirframe: false,
        vignette: true,
      ),
    );
  }
}
