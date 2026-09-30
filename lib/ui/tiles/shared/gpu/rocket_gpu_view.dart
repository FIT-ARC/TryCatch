import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vector_math/vector_math_64.dart' as vm64;

import '../flight_3d_common.dart' show flightSunDir, paintCompass;
import '../rocket_mesh.dart';
import './rocket_gpu_data.dart';
import './scene_resources.dart';

/// GPU-rendered rocket attitude view (Flutter GPU via `flutter_scene`).
///
/// The airframe uploads once per configuration ([showNoseCone]/[showParachute]);
/// attitude and camera changes only move the node/camera — no per-frame CPU
/// projection, depth sort, or `drawPath`-per-triangle. The engine depth buffer
/// replaces the painter's algorithm.
class RocketGpuView extends StatefulWidget {
  final double pitchDeg;
  final double yawDeg;
  final double rollDeg;
  final double cameraAzimuthDeg;
  final double cameraElevationDeg;
  final bool showNoseCone;
  final bool showParachute;

  const RocketGpuView({
    super.key,
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.cameraAzimuthDeg,
    required this.cameraElevationDeg,
    this.showNoseCone = true,
    this.showParachute = false,
  });

  @override
  State<RocketGpuView> createState() => _RocketGpuViewState();
}

/// Vertical FOV of the orientation viewer camera (matches the painter's 42°).
const double rocketGpuFovY = 42 * math.pi / 180;

/// Camera framing that centres the visible stack on screen.
({vm64.Vector3 target, double distance}) rocketFramingGpu({
  required bool showNoseCone,
  required bool showParachute,
  double scale = 0.9,
}) {
  final top = showParachute
      ? RocketMesh.bodyTop + ParachuteMesh.apexY * 1.5
      : showNoseCone
          ? RocketMesh.noseTip
          : RocketMesh.bodyTop;
  return (
    target: vm64.Vector3(0, (top + RocketMesh.finBottom) / 2 * scale, 0),
    distance: showParachute ? 4.2 : 3.2,
  );
}

class _RocketGpuViewState extends State<RocketGpuView> {
  @override
  Widget build(BuildContext context) {
    // Geometry/material constructors touch the base shader library, so mount
    // the engine subtree only once the static resources are loaded.
    return SceneGate(
        builder: (context) => _EngineRocketGpuView(widget: widget));
  }
}

/// Post-gate rocket view: static resources are loaded, so all engine
/// geometry/material constructors are safe to call during build.
class _EngineRocketGpuView extends StatefulWidget {
  final RocketGpuView widget;

  const _EngineRocketGpuView({required this.widget});

  @override
  State<_EngineRocketGpuView> createState() => _EngineRocketGpuViewState();
}

class _EngineRocketGpuViewState extends State<_EngineRocketGpuView> {
  static const double _modelScale = 0.9;

  late final fs.Scene _engineScene = fs.Scene()
    ..directionalLight = fs.DirectionalLight(
      // Sun near the zenith, where the gradient sky is brightest — the same
      // [flightSunDir] the flight views use, mirrored into the engine's
      // frame (see `_attitudeTransform`).
      direction: vm.Vector3(
        flightSunDir.x,
        -flightSunDir.y,
        -flightSunDir.z,
      ),
      intensity: 1.8,
    );

  fs.MeshGeometry? _airframe;
  fs.MeshGeometry? _chute;
  late final fs.Material _material = fs.PhysicallyBasedMaterial()
    ..metallicFactor = 0.0
    ..roughnessFactor = 0.50;

  @override
  void initState() {
    super.initState();
    _rebuildGeometry();
  }

  @override
  void didUpdateWidget(_EngineRocketGpuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.widget.showNoseCone != widget.widget.showNoseCone ||
        oldWidget.widget.showParachute != widget.widget.showParachute) {
      _rebuildGeometry();
    }
  }

  void _rebuildGeometry() {
    final airframe = buildRocketGpuData(
      showNoseCone: widget.widget.showNoseCone,
    );
    _airframe = fs.MeshGeometry.fromArrays(
      positions: airframe.positions,
      normals: airframe.normals,
      colors: airframe.colors,
    );
    _chute = widget.widget.showParachute ? _buildChute() : null;
  }

  fs.MeshGeometry _buildChute() {
    final chute = buildParachuteGpuData();
    return fs.MeshGeometry.fromArrays(
      positions: chute.positions,
      normals: chute.normals,
      colors: chute.colors,
    );
  }

  /// Attitude as an engine transform, composed with the mirroring root that
  /// cancels the engine's horizontal mirror (the encoder compensates the
  /// reversed winding of mirrored subtrees, so culling behaves as
  /// unmirrored).
  vm.Matrix4 _attitudeTransform() {
    final m = RocketMesh.orientationMatrix(
      pitchDeg: widget.widget.pitchDeg,
      yawDeg: widget.widget.yawDeg,
      rollDeg: widget.widget.rollDeg,
      scale: _modelScale,
    );
    final attitude = vm.Matrix4.fromList(m.storage);
    final mirror = vm.Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0);
    return mirror * attitude;
  }

  /// The canopy hangs world-up from the popped tube mouth: it rides the
  /// attitude only to find the mouth position, never to tilt with the
  /// airframe. Scaled 1.5x relative to the airframe.
  vm.Matrix4 _chuteTransform() {
    final m = RocketMesh.orientationMatrix(
      pitchDeg: widget.widget.pitchDeg,
      yawDeg: widget.widget.yawDeg,
      rollDeg: widget.widget.rollDeg,
      scale: _modelScale,
    );
    final mouth = m.transformed3(vm64.Vector3(0, RocketMesh.bodyTop, 0));
    final mount = vm64.Matrix4.translation(mouth);
    final scale = vm64.Matrix4.identity()
      ..scaleByDouble(
        _modelScale * 1.5,
        _modelScale * 1.5,
        _modelScale * 1.5,
        1.0,
      );
    final mirror = vm64.Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0);
    return vm.Matrix4.fromList((mirror * (mount * scale)).storage);
  }

  /// Builds the engine camera (mirrored, see `_attitudeTransform`) plus the
  /// standard GL view of the unmirrored camera for the compass painter, so
  /// the gizmo matches the rendered frame.
  ({fs.PerspectiveCamera camera, vm64.Matrix4 compassView}) _cameraSetup() {
    final framing = rocketFramingGpu(
      showNoseCone: widget.widget.showNoseCone,
      showParachute: widget.widget.showParachute,
      scale: _modelScale,
    );
    final azimuth = widget.widget.cameraAzimuthDeg * math.pi / 180;
    final elevation = widget.widget.cameraElevationDeg * math.pi / 180;
    final camDir = vm64.Vector3(
      math.cos(elevation) * math.sin(azimuth),
      math.sin(elevation),
      math.cos(elevation) * math.cos(azimuth),
    );
    final eye = vm64.Vector3(
          framing.target.x,
          framing.target.y,
          framing.target.z,
        ) +
        camDir.scaled(framing.distance);
    final target = vm64.Vector3(
      framing.target.x,
      framing.target.y,
      framing.target.z,
    );
    final camera = fs.PerspectiveCamera(
      fovRadiansY: rocketGpuFovY,
      // The scene content is mirrored through the x=0 plane (see
      // `_attitudeTransform`), so the camera renders from its mirror image;
      // the pair cancels the engine's horizontal mirror.
      position: vm.Vector3(-eye.x, eye.y, eye.z),
      target: vm.Vector3(target.x, target.y, target.z),
      fovNear: 0.1,
      fovFar: 20.0,
    );
    final compassView =
        vm64.makeViewMatrix(eye, target, vm64.Vector3(0, 1, 0));
    return (camera: camera, compassView: compassView);
  }

  @override
  Widget build(BuildContext context) {
    final setup = _cameraSetup();
    return Stack(
      fit: StackFit.expand,
      children: [
        fs.SceneView(
          _engineScene,
          autoTick: false,
          camera: setup.camera,
          children: [
            fs.SceneNode(
              transform: _attitudeTransform(),
              children: [
                fs.SceneMesh(geometry: _airframe!, material: _material),
              ],
            ),
            if (_chute != null)
              fs.SceneNode(
                transform: _chuteTransform(),
                children: [
                  fs.SceneMesh(geometry: _chute!, material: _material),
                ],
              ),
          ],
        ),
        IgnorePointer(
          child: CustomPaint(painter: _CompassPainter(setup.compassView)),
        ),
      ],
    );
  }
}

/// Corner E/U/N compass through the engine camera's view matrix, matching the
/// flight views' gizmo.
class _CompassPainter extends CustomPainter {
  final vm64.Matrix4 view;

  _CompassPainter(this.view);

  @override
  void paint(Canvas canvas, Size size) => paintCompass(canvas, size, view);

  @override
  bool shouldRepaint(covariant _CompassPainter old) =>
      old.view != view;
}
