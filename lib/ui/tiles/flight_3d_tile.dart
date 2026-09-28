import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/flight_3d_shell.dart';
import './shared/orbit_camera.dart';
import './shared/rocket_mesh.dart';

/// 3D flight path view: the rocket flies through a metric world (east/up/
/// south metres relative to the launch site), leaving its trail behind it.
/// The launch site is marked with a flag on a gridded ground plane, and the
/// camera can chase the rocket, orbit the whole field, or orbit freely.
///
/// Positions come from GPS fixes; a stale GPS estimate is shown as a single
/// violet dead-reckoning point (never a trail). The rocket stands on its tail
/// at the reported position. Scene, cameras and painters are shared with the
/// satellite views via `flight_3d_common.dart`.
class Flight3dTile extends ConsumerStatefulWidget {
  const Flight3dTile({super.key});

  @override
  ConsumerState<Flight3dTile> createState() => _Flight3dWidgetState();
}

class _Flight3dWidgetState extends ConsumerState<Flight3dTile>
    with Flight3dShellState {
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
    );
    if (scene == null) {
      // Frames are arriving but no position anchor (no fix, no site) yet.
      return Center(child: WaitingForData());
    }

    return Flight3dShell(
      painter: _FlightPainter(
        scene: scene,
        mode: mode,
        azimuthDeg: camera.azimuthDeg,
        elevationDeg: camera.elevationDeg,
        zoom: zoom,
      ),
      mode: mode,
      onMode: setShellMode,
      onZoomBy: zoomBy,
      onResetZoom: resetZoom,
      onOrbit: orbitBy,
    );
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

class _FlightPainter extends CustomPainter {
  final FlightScene scene;
  final FlightCameraMode mode;
  final double azimuthDeg;
  final double elevationDeg;
  final double zoom;

  /// Real-life scale: the mesh spans 2.15 model units for an ~80 cm airframe.
  static const double _rocketScale = 0.8 / 2.15;

  _FlightPainter({
    required this.scene,
    required this.mode,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Nothing may leak outside the tile bounds.
    canvas.clipRect(Offset.zero & size);

    final aspect = size.width / math.max(1.0, size.height);
    final cam = computeFlightCamera(
      scene: scene,
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
      zoom: zoom,
      aspect: aspect,
    );
    // The airframe pivots about its CG (Raketa.ork mass budget) and the
    // trail meets its middle; near the ground the anchor lifts just enough
    // to keep the tail/belly out of the plane.
    final anchor = cgAnchorPos(
      rocketPos: scene.rocketPos,
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      scale: _rocketScale,
    );
    paintGroundPlain(canvas, scene, cam.vp, size);
    paintFlightTrail(canvas, scene, cam.vp, size, tipOverride: anchor);
    paintLaunchSite(canvas, scene, cam.vp, size);
    paintDropLineAndDeadReckoning(canvas, scene, cam.vp, size, anchorOverride: anchor);
    paintRocketMesh(
      canvas,
      size,
      cam.vp,
      cam.view,
      cam.lightDir,
      rocketPos: anchor,
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      rollDeg: scene.rollDeg,
      scale: _rocketScale,
      baseLift: -RocketMesh.cgY,
      // Airframe configuration comes from the FSM state (cone pops at
      // apogee, canopy renders under parachute only).
      showNoseCone: scene.showNoseCone,
      showParachute: scene.showParachute,
    );
    paintCompass(canvas, size, cam.view);
  }

  @override
  bool shouldRepaint(covariant _FlightPainter old) =>
      !identical(old.scene, scene) ||
      old.mode != mode ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.zoom != zoom;
}
