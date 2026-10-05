import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/gpu/rocket_gpu_view.dart';
import './shared/orbit_camera.dart';
import './shared/replay_vsync.dart';

/// 3D rocket orientation view: the parametric rocket mesh rendered on the
/// GPU (`RocketGpuView`), transformed by the rocket's attitude. Drag orbits
/// the shared camera; a corner compass shows the North / East / Up world
/// axes with the same colours as the flight-path view. No zoom — the fixed
/// framing always fits the airframe.
///
/// Attitude is rocket-oriented: pitch = tilt from vertical, yaw = heading,
/// roll = spin around the longitudinal axis. Drag orbits the shared camera.
class Rocket3dTile extends ConsumerStatefulWidget {
  const Rocket3dTile({super.key});

  @override
  ConsumerState<Rocket3dTile> createState() => _Rocket3dWidgetState();
}

class _Rocket3dWidgetState extends ConsumerState<Rocket3dTile>
    with SingleTickerProviderStateMixin, ReplayVsync {
  @override
  Widget build(BuildContext context) {
    final latest = ref.watch(telemetryStoreProvider).latest;
    final camera = ref.watch(orbitCameraProvider);
    final replay = ref.watch(replayProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    // Airframe configuration comes straight from the connector's FSM
    // state: the cone pops at apogee, the canopy renders under parachute
    // only (landed keeps the nose-cone tile UNLOCKED but hides the
    // collapsed chute).
    final airframe = ref
        .watch(activeConnectorProvider)
        .stateForId(latest.fsmStateId);
    final showNoseCone = airframe.hasNosecone;
    final showParachute = airframe.showsParachute;

    // Replay smoothing also steadies the rotation: same smoothed recorded
    // attitude the flight views use, so the orientation viewer stops
    // jittering when the toggle is on. Raw replay and live stay untouched.
    // With smoothing the rotation interpolates between packets at the
    // display refresh rate via the vsync display clock.
    final attitude = resolveDisplayAttitude(
      pitchDeg: latest.pitch,
      yawDeg: latest.yaw,
      rollDeg: latest.roll,
      replay: replay,
      positionMsOverride: replayDisplayMs(replay),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) {
        ref.read(orbitCameraProvider.notifier).orbit(details.delta);
      },
      child: RocketGpuView(
        pitchDeg: attitude.pitchDeg,
        yawDeg: attitude.yawDeg,
        rollDeg: attitude.rollDeg,
        cameraAzimuthDeg: camera.azimuthDeg,
        cameraElevationDeg: camera.elevationDeg,
        showNoseCone: showNoseCone,
        showParachute: showParachute,
      ),
    );
  }
}
