import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vector_math/vector_math_64.dart' as vm64;

import '../flight_3d_common.dart' show paintCompass;
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
  final double zoom;

  const RocketGpuView({
    super.key,
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.cameraAzimuthDeg,
    required this.cameraElevationDeg,
    this.showNoseCone = true,
    this.showParachute = false,
    this.zoom = 1.0,
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
      ? RocketMesh.bodyTop + ParachuteMesh.apexY
      : showNoseCone
          ? RocketMesh.noseTip
          : RocketMesh.bodyTop;
  return (
    target: vm64.Vector3(0, (top + RocketMesh.finBottom) / 2 * scale, 0),
    distance: showParachute ? 3.6 : 3.2,
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

  fs.MeshGeometry? _geometry;
  late final fs.Material _material = fs.PhysicallyBasedMaterial()
    ..metallicFactor = 0.0
    ..roughnessFactor = 0.55;

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
    final data = buildRocketGpuData(
      showNoseCone: widget.widget.showNoseCone,
      showParachute: widget.widget.showParachute,
    );
    _geometry = fs.MeshGeometry.fromArrays(
      positions: data.positions,
      normals: data.normals,
      colors: data.colors,
    );
  }

  /// Attitude as an engine transform, converted from the shared
  /// [RocketMesh.orientationMatrix] so the GPU and the scene builder agree.
  vm.Matrix4 _attitudeTransform() {
    final m = RocketMesh.orientationMatrix(
      pitchDeg: widget.widget.pitchDeg,
      yawDeg: widget.widget.yawDeg,
      rollDeg: widget.widget.rollDeg,
      scale: _modelScale,
    );
    return vm.Matrix4.fromList(m.storage);
  }

  fs.PerspectiveCamera _camera() {
    final framing = rocketFramingGpu(
      showNoseCone: widget.widget.showNoseCone,
      showParachute: widget.widget.showParachute,
      scale: _modelScale,
    );
    final azimuth = widget.widget.cameraAzimuthDeg * math.pi / 180;
    final elevation = widget.widget.cameraElevationDeg * math.pi / 180;
    final camDir = vm.Vector3(
      math.cos(elevation) * math.sin(azimuth),
      math.sin(elevation),
      math.cos(elevation) * math.cos(azimuth),
    );
    return fs.PerspectiveCamera(
      fovRadiansY: rocketGpuFovY,
      position: vm.Vector3(
        framing.target.x,
        framing.target.y,
        framing.target.z,
      ) +
          camDir.scaled(framing.distance / widget.widget.zoom),
      target: vm.Vector3(
        framing.target.x,
        framing.target.y,
        framing.target.z,
      ),
      fovNear: 0.1,
      fovFar: 20.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera();
    final viewMatrix = vm64.Matrix4.fromList(camera.getViewMatrix().storage);
    return Stack(
      fit: StackFit.expand,
      children: [
        fs.SceneView.declarative(
          autoTick: false,
          camera: camera,
          children: [
            fs.SceneNode(
              transform: _attitudeTransform(),
              children: [
                fs.SceneMesh(geometry: _geometry!, material: _material),
              ],
            ),
          ],
        ),
        IgnorePointer(
          child: CustomPaint(painter: _CompassPainter(viewMatrix)),
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
