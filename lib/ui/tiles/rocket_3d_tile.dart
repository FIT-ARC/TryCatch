import 'package:flutter/gestures.dart'
    show PointerPanZoomUpdateEvent, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/trackpad_zoom.dart' show scrollZoomFactor;
import './shared/flight_3d_common.dart';
import './shared/gpu/rocket_gpu_view.dart';
import './shared/orbit_camera.dart';

/// 3D rocket orientation view.
///
/// A small software renderer built on `vector_math`: the parametric rocket
/// mesh is transformed by the rocket's attitude, lit with flat shading and
/// depth-sorted (painter's algorithm). Drag orbits the shared camera; a
/// corner compass shows the North / East / Up world axes with the same
/// colours as the flight-path view.
///
/// Attitude is rocket-oriented: pitch = tilt from vertical, yaw = heading,
/// roll = spin around the longitudinal axis. Drag orbits the shared camera,
/// the wheel zooms, double-tap resets the zoom.
class Rocket3dTile extends ConsumerStatefulWidget {
  const Rocket3dTile({super.key});

  @override
  ConsumerState<Rocket3dTile> createState() => _Rocket3dWidgetState();
}

/// Wheel-zoom step for the 3D views: scroll up (negative dy) zooms in,
/// scroll down zooms out — the same sense as [Flight3dShell] — clamped to
/// the usable framing range. Delegates to [scrollZoomFactor] so wheel and
/// trackpad share one curve.
@visibleForTesting
double zoomAfterWheel(double current, double scrollDeltaDy) =>
    (current * scrollZoomFactor(scrollDeltaDy)).clamp(0.5, 3.0);

class _Rocket3dWidgetState extends ConsumerState<Rocket3dTile> {
  double _zoom = 1.0;

  /// While a trackpad gesture is active its swipe/pinch zooms (handled
  /// below) and must NOT also orbit: the framework routes trackpad swipes
  /// to drag recognizers, so [GestureDetector.onPanUpdate] would otherwise
  /// tilt the camera for the same gesture. A real press (mouse/touch)
  /// always clears the flag, so a lost gesture-end can never wedge it on.
  bool _trackpadZooming = false;
  double _lastScale = 1.0;

  void _trackpadZoom(PointerPanZoomUpdateEvent event) {
    _trackpadZooming = true;
    final factor =
        scrollZoomFactor(event.panDelta.dy) * (event.scale / _lastScale);
    _lastScale = event.scale;
    if (factor != 1.0) {
      setState(() => _zoom = (_zoom * factor).clamp(0.5, 3.0));
    }
  }

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

    // Replay smoothing also steadies the rotation: same trailing-average
    // attitude the flight views use, so the orientation viewer stops
    // jittering when the toggle is on. Raw replay and live stay untouched.
    final attitude = resolveDisplayAttitude(
      pitchDeg: latest.pitch,
      yawDeg: latest.yaw,
      rollDeg: latest.roll,
      replay: replay,
    );
    final pitchDeg = attitude.pitchDeg;
    final yawDeg = attitude.yawDeg;
    final rollDeg = attitude.rollDeg;

    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        setState(() => _zoom = zoomAfterWheel(_zoom, event.scrollDelta.dy));
      },
      onPointerPanZoomStart: (_) {
        _trackpadZooming = true;
        _lastScale = 1.0;
      },
      onPointerPanZoomUpdate: _trackpadZoom,
      onPointerPanZoomEnd: (_) => _trackpadZooming = false,
      // A real press is never part of a trackpad gesture: clears a flag
      // whose gesture-end was lost, so drag-orbit can never wedge off.
      onPointerDown: (_) => _trackpadZooming = false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          if (_trackpadZooming) return;
          ref.read(orbitCameraProvider.notifier).orbit(details.delta);
        },
        onDoubleTap: () => setState(() => _zoom = 1.0),
        child: RocketGpuView(
          pitchDeg: pitchDeg,
          yawDeg: yawDeg,
          rollDeg: rollDeg,
          cameraAzimuthDeg: camera.azimuthDeg,
          cameraElevationDeg: camera.elevationDeg,
          showNoseCone: showNoseCone,
          showParachute: showParachute,
          zoom: _zoom,
        ),
      ),
    );
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

