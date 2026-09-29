import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vector_math/vector_math_64.dart' as vm64;

import '../../../../theme/app_colors.dart';
import '../flight_3d_common.dart';
import '../rocket_mesh.dart' show RocketMesh;
import '../satellite_ground.dart';
import '../tile_io.dart' show satelliteAttribution;
import './rocket_gpu_data.dart';
import './scene_resources.dart';
import './terrain_gpu_data.dart';

/// Bottom-right imagery credit for the satellite-ground flight views.
Widget satelliteAttributionOverlay() => Positioned(
      right: 4,
      bottom: 2,
      child: Text(
        satelliteAttribution,
        style: TextStyle(
          fontSize: 9,
          color: Colors.black.withValues(alpha: 0.45),
        ),
      ),
    );

/// Converts a `vector_math_64` scene vector to the engine's `vector_math`.
vm.Vector3 toEngineVec(vm64.Vector3 v) => vm.Vector3(v.x, v.y, v.z);

/// Converts a UI color to an engine RGBA vector.
vm.Vector4 toEngineColor(Color c) => vm.Vector4(c.r, c.g, c.b, c.a);

/// Sun direction used to bake the terrain hillshade (fixed so the drape is
/// camera-independent).
final vm.Vector3 terrainSunDir = vm.Vector3(0.45, 0.78, 0.30).normalized();

/// GPU-rendered 3D flight view (Flutter GPU via `flutter_scene`).
///
/// Renders the satellite drape (imagery textures + DEM meshes), the plain
/// ground grid, the GPS trail, the CG-anchored airframe and the procedural
/// sky; the residual world-space annotations (launch flag, drop line,
/// dead-reckoning connector, shadow disk) and the screen-space compass /
/// under-ground badge ride on a thin 2D overlay painter that reuses the same
/// camera.
class FlightGpuView extends StatefulWidget {
  final FlightScene scene;
  final FlightLens lens;

  /// Satellite drape, when imagery is loaded. Null renders the plain grid.
  final SatelliteTerrain? terrain;
  final TerrainMeshSet? meshes;
  final FlightAnchor? anchor;

  /// Onboard lens: hide the airframe and paint the glass vignette.
  final bool showAirframe;
  final bool vignette;

  const FlightGpuView({
    super.key,
    required this.scene,
    required this.lens,
    this.terrain,
    this.meshes,
    this.anchor,
    this.showAirframe = true,
    this.vignette = false,
  });

  @override
  State<FlightGpuView> createState() => _FlightGpuViewState();
}

class _FlightGpuViewState extends State<FlightGpuView> {
  @override
  Widget build(BuildContext context) {
    // Geometry constructors such as `LineSegmentsGeometry` touch the base
    // shader library synchronously, so mount the engine subtree only once
    // the static resources are loaded.
    return SceneGate(
      builder: (context) => _EngineFlightGpuView(
        scene: widget.scene,
        lens: widget.lens,
        terrain: widget.terrain,
        meshes: widget.meshes,
        anchor: widget.anchor,
        showAirframe: widget.showAirframe,
        vignette: widget.vignette,
      ),
    );
  }
}

/// Post-gate flight view: static resources are loaded, so all engine
/// geometry/material constructors are safe to call during build.
class _EngineFlightGpuView extends StatefulWidget {
  final FlightScene scene;
  final FlightLens lens;
  final SatelliteTerrain? terrain;
  final TerrainMeshSet? meshes;
  final FlightAnchor? anchor;
  final bool showAirframe;
  final bool vignette;

  const _EngineFlightGpuView({
    required this.scene,
    required this.lens,
    this.terrain,
    this.meshes,
    this.anchor,
    this.showAirframe = true,
    this.vignette = false,
  });

  @override
  State<_EngineFlightGpuView> createState() => _EngineFlightGpuViewState();
}

class _EngineFlightGpuViewState extends State<_EngineFlightGpuView> {
  static const double _rocketScale = 0.8 / 2.15;

  late final fs.Scene _engineScene;

  fs.Geometry? _grid;
  ({double half, double step})? _gridKey;
  fs.PolylineGeometry? _trail;
  int _trailPoints = 0;
  fs.MeshGeometry? _rocket;
  bool? _rocketNose;
  bool? _rocketChute;

  // Terrain tiers, keyed by the source patch image so a new site rebuilds.
  final Map<ui.Image, fs.Texture2D> _tierTextures = {};
  final Map<ui.Image, fs.MeshGeometry> _tierMeshes = {};
  SatelliteTerrain? _builtTerrain;
  TerrainMeshSet? _builtMeshSource;
  bool _uploading = false;

  late final fs.Material _gridMaterial = fs.UnlitMaterial()
    ..baseColorFactor = vm.Vector4(0.42, 0.45, 0.5, 1.0);
  late final fs.Material _trailMaterial = fs.UnlitMaterial()
    ..baseColorFactor = toEngineColor(AppColors.seriesGpsTrack);
  late final fs.Material _rocketMaterial = fs.PhysicallyBasedMaterial()
    ..metallicFactor = 0.0
    ..roughnessFactor = 0.55;

  @override
  void initState() {
    super.initState();
    _engineScene = fs.Scene();
    _engineScene.skybox = fs.Skybox(_skySource());
  }

  bool get _dark => AppThemeMode.instance.value;

  fs.GradientSkySource _skySource() {
    final dark = _dark;
    return fs.GradientSkySource(
      zenithColor: dark
          ? vm.Vector3(0.031, 0.043, 0.109)
          : vm.Vector3(0.498, 0.659, 0.851),
      horizonColor: dark
          ? vm.Vector3(0.239, 0.227, 0.302)
          : vm.Vector3(0.914, 0.902, 0.925),
      groundColor: dark
          ? vm.Vector3(0.165, 0.180, 0.165)
          : vm.Vector3(0.717, 0.737, 0.682),
    );
  }

  /// Grid extents mirror the painter's 1-2-5 rule so the grid never rescales
  /// with the camera.
  ({double half, double step}) _gridExtents(FlightScene scene) {
    final gridHalf = math.min(
      10000.0,
      _niceCeil(
          math.max(60.0, math.max(scene.maxHoriz * 1.3, scene.maxAlt * 0.6))),
    );
    final step = _niceCeil(gridHalf / 8);
    final n = (gridHalf / step).ceil();
    return (half: n * step, step: step);
  }

  static double _niceCeil(double v) {
    if (v <= 0) return 1;
    final mag =
        math.pow(10, (math.log(v) / math.ln10).floorToDouble()).toDouble();
    for (final m in const [1.0, 2.0, 5.0, 10.0]) {
      if (v <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  void _ensureGrid(FlightScene scene) {
    final extents = _gridExtents(scene);
    if (_gridKey != null &&
        _gridKey!.half == extents.half &&
        _gridKey!.step == extents.step) {
      return;
    }
    _gridKey = extents;
    final half = extents.half;
    final step = extents.step;
    final n = (half / step).ceil();
    final segments = <double>[];
    for (var k = -n; k <= n; k++) {
      final off = k * step;
      segments.addAll([off, 0, -half, off, 0, half]);
      segments.addAll([-half, 0, off, half, 0, off]);
    }
    _grid = fs.LineSegmentsGeometry(
      fs.LineSegmentData(positions: Float32List.fromList(segments)),
      width: math.max(1.0, step * 0.02),
    );
  }

  void _ensureTrail(FlightScene scene) {
    if (scene.trail.length < 2) {
      _trail = null;
      _trailPoints = 0;
      return;
    }
    if (_trail == null || _trailPoints != scene.trail.length) {
      _trail = fs.PolylineGeometry(
        [for (final p in scene.trail) toEngineVec(p)],
        width: 2.2,
        widthMode: fs.PolylineWidthMode.screenPixels,
      );
      _trailPoints = scene.trail.length;
    }
  }

  void _ensureRocket(FlightScene scene) {
    if (_rocket != null &&
        _rocketNose == scene.showNoseCone &&
        _rocketChute == scene.showParachute) {
      return;
    }
    _rocketNose = scene.showNoseCone;
    _rocketChute = scene.showParachute;
    final data = buildRocketGpuData(
      showNoseCone: scene.showNoseCone,
      showParachute: scene.showParachute,
    );
    _rocket = fs.MeshGeometry.fromArrays(
      positions: data.positions,
      normals: data.normals,
      colors: data.colors,
    );
  }

  /// Builds the GPU tiers (mesh + texture) for the current terrain, once per
  /// terrain/mesh set. Texture uploads are async; the frame renders the
  /// already-uploaded tiers until each lands.
  void _ensureTerrain(SatelliteTerrain? terrain, TerrainMeshSet? meshes) {
    if (terrain == null || meshes == null) {
      _builtTerrain = null;
      _builtMeshSource = null;
      return;
    }
    if (identical(_builtTerrain, terrain) &&
        identical(_builtMeshSource, meshes)) {
      return;
    }
    _builtTerrain = terrain;
    _builtMeshSource = meshes;
    _tierMeshes.clear();
    void add(ui.Image image, TerrainMesh mesh, double lift) {
      if (_tierMeshes.containsKey(image)) return;
      final data = buildTerrainGpuData(
        mesh: mesh,
        imageWidth: image.width,
        imageHeight: image.height,
        sunDir: terrainSunDir,
        yOffset: lift,
      );
      _tierMeshes[image] = fs.MeshGeometry.fromArrays(
        positions: data.positions,
        normals: data.normals,
        texCoords: data.texCoords,
        colors: data.colors,
        indices: data.indices,
      );
    }

    add(terrain.outer.image, meshes.outer, outerTierLift);
    final mid = terrain.mid;
    final midMesh = meshes.mid;
    if (mid != null && midMesh != null) add(mid.image, midMesh, midTierLift);
    final pad = terrain.pad;
    final padMesh = meshes.pad;
    if (pad != null && padMesh != null) add(pad.image, padMesh, padTierLift);
    _uploadTextures(terrain);
  }

  void _uploadTextures(SatelliteTerrain terrain) {
    if (_uploading) return;
    final pending = <ui.Image>[
      terrain.outer.image,
      if (terrain.mid != null) terrain.mid!.image,
      if (terrain.pad != null) terrain.pad!.image,
    ].where((i) => !_tierTextures.containsKey(i)).toList();
    if (pending.isEmpty) return;
    _uploading = true;
    Future.wait([
      for (final image in pending)
        fs.Texture2D.fromImage(image).then((t) => (image, t)),
    ]).then((uploaded) {
      if (!mounted) return;
      setState(() {
        for (final (image, texture) in uploaded) {
          _tierTextures[image] = texture;
        }
        _uploading = false;
      });
    }).catchError((Object _) {
      _uploading = false;
    });
  }

  /// The scene with the rocket and trail clamped onto the DEM surface, plus the
  /// terrain height under the rocket (mirrors `SatFlightPainter.paint`).
  ({FlightScene display, double surfaceY, double under}) _displayScene(
      FlightScene scene, FlightAnchor? anchor, ElevationGrid? dem) {
    if (dem == null || anchor == null) {
      return (display: scene, surfaceY: 0, under: 0);
    }
    double surfaceAt(vm64.Vector3 p) => terrainSurfaceY(
          dem,
          eastM: p.x,
          southM: p.z,
          lat0: anchor.lat,
          lon0: anchor.lon,
          cosLat0: anchor.cosLat,
        );
    final reported = scene.rocketPos;
    final surfaceY = surfaceAt(reported);
    final under = surfaceY - reported.y;
    final clampedPos =
        under > 0 ? vm64.Vector3(reported.x, surfaceY, reported.z) : reported;
    final clampedTrail = <vm64.Vector3>[];
    for (final p in scene.trail) {
      final s = surfaceAt(p);
      clampedTrail.add(s > p.y ? vm64.Vector3(p.x, s, p.z) : p);
    }
    final display = FlightScene(
      trail: clampedTrail,
      rocketPos: clampedPos,
      rocketIsDeadReckoning: scene.rocketIsDeadReckoning,
      maxAlt: scene.maxAlt,
      maxHoriz: scene.maxHoriz,
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      rollDeg: scene.rollDeg,
      showNoseCone: scene.showNoseCone,
      showParachute: scene.showParachute,
      siteName: scene.siteName,
    );
    return (display: display, surfaceY: surfaceY, under: under);
  }

  fs.PerspectiveCamera _engineCamera(FlightCamera cam) {
    final row = cam.view.getRow(1);
    return fs.PerspectiveCamera(
      fovRadiansY: cam.fovY,
      position: vm.Vector3(cam.eye.x, cam.eye.y, cam.eye.z),
      target: vm.Vector3(cam.target.x, cam.target.y, cam.target.z),
      up: vm.Vector3(row.x, row.y, row.z),
      fovNear: (cam.dist * 0.02).clamp(0.05, 50.0),
      fovFar: cam.eye.distanceTo(cam.target) + 90000.0,
    );
  }

  /// CG-anchored rocket position (the painter's `cgAnchorPos`).
  vm64.Vector3 _cgAnchor(FlightScene scene, double groundY) => cgAnchorPos(
        rocketPos: scene.rocketPos,
        pitchDeg: scene.pitchDeg,
        yawDeg: scene.yawDeg,
        scale: _rocketScale,
        groundY: groundY,
      );

  vm.Matrix4 _rocketTransform(FlightScene scene, vm64.Vector3 anchor) {
    final m = RocketMesh.orientationMatrix(
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      rollDeg: scene.rollDeg,
      scale: _rocketScale,
    );
    final transform = vm.Matrix4.fromList(m.storage);
    transform.setTranslationRaw(anchor.x, anchor.y, anchor.z);
    return transform;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final aspect = size.width / math.max(1.0, size.height);
        final display = _displayScene(
          widget.scene,
          widget.anchor,
          widget.terrain?.dem,
        );
        final scene = display.display;

        final cam = widget.lens.compute(scene: scene, aspect: aspect);
        final clamped = widget.terrain != null
            ? clampEyeAboveTerrain(
                cam,
                terrainSurfaceY(
                      widget.terrain!.dem,
                      eastM: cam.eye.x,
                      southM: cam.eye.z,
                      lat0: widget.anchor?.lat ?? 0,
                      lon0: widget.anchor?.lon ?? 0,
                      cosLat0: widget.anchor?.cosLat ?? 1,
                    ) +
                    2.0,
              )
            : cam;

        _ensureTerrain(widget.terrain, widget.meshes);
        _ensureTrail(scene);
        if (widget.showAirframe) _ensureRocket(scene);
        final hasTerrain = _tierMeshes.isNotEmpty;
        if (!hasTerrain) _ensureGrid(scene);

        final meshAnchor = _cgAnchor(scene, display.surfaceY);
        final engineCamera = _engineCamera(clamped);

        final children = <Widget>[
          if (hasTerrain)
            for (final entry in _tierMeshes.entries)
              fs.SceneMesh(
                geometry: entry.value,
                material: _tierMaterial(entry.key),
              ),
          if (!hasTerrain && _grid != null)
            fs.SceneMesh(geometry: _grid!, material: _gridMaterial),
          if (_trail != null)
            fs.SceneMesh(geometry: _trail!, material: _trailMaterial),
          if (widget.showAirframe && _rocket != null)
            fs.SceneNode(
              transform: _rocketTransform(scene, meshAnchor),
              children: [
                fs.SceneMesh(geometry: _rocket!, material: _rocketMaterial),
              ],
            ),
        ];

        _trail?.updateForCamera(engineCamera, size);
        _engineScene.skybox = fs.Skybox(_skySource());

        final view = fs.SceneView(
          _engineScene,
          autoTick: false,
          camera: engineCamera,
          children: children,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            view,
            IgnorePointer(
              child: CustomPaint(
                painter: _MarkerOverlayPainter(
                  scene: scene,
                  cam: clamped,
                  anchor: meshAnchor,
                  groundY: display.surfaceY,
                  under: display.under,
                  satTerrain: hasTerrain,
                  vignette: widget.vignette,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  fs.Material _tierMaterial(ui.Image image) {
    final material = fs.UnlitMaterial(
      colorTexture: _tierTextures[image],
    )..alphaMode = fs.AlphaMode.blend;
    return material;
  }
}

/// World-space annotations and screen-space compass/badge, drawn over the GPU
/// frame through the same camera the engine used.
class _MarkerOverlayPainter extends CustomPainter {
  final FlightScene scene;
  final FlightCamera cam;
  final vm64.Vector3 anchor;
  final double groundY;
  final double under;
  final bool satTerrain;
  final bool vignette;

  _MarkerOverlayPainter({
    required this.scene,
    required this.cam,
    required this.anchor,
    required this.groundY,
    required this.under,
    required this.satTerrain,
    required this.vignette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (satTerrain) {
      paintShadowDisk(
        canvas,
        cam.vp,
        size,
        vm64.Vector3(scene.rocketPos.x, groundY + 0.05, scene.rocketPos.z),
        1.2,
      );
    }
    paintLaunchSite(canvas, scene, cam.vp, size);
    paintDropLineAndDeadReckoning(
      canvas,
      scene,
      cam.vp,
      size,
      anchorOverride: anchor,
      groundY: groundY,
    );
    if (under > 0.05) {
      paintUnderGroundLabel(
        canvas,
        cam.vp,
        size,
        anchor,
        formatUnderMeters(under),
      );
    }
    if (!satTerrain) paintCompass(canvas, size, cam.view);
    if (vignette) paintVignette(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _MarkerOverlayPainter old) =>
      !identical(old.scene, scene) ||
      !identical(old.cam, cam) ||
      old.groundY != groundY ||
      old.under != under ||
      old.satTerrain != satTerrain ||
      old.vignette != vignette;
}
