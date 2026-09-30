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

/// Bottom-left hint shown while imagery is fetching or the retained drape
/// meshes are still building (the tile falls back to the plain grid).
Widget satelliteLoadingOverlay() => Positioned(
      left: 8,
      bottom: 4,
      child: Text(
        'Loading imagery…',
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 0.5,
          color: AppColors.mutedForeground,
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
/// ground grid, the GPS trail, the ground blob shadow, the CG-anchored
/// airframe and the procedural sky; the residual world-space annotations
/// (launch flag, dead-reckoning connector) and the screen-space compass /
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

/// GPU drape resources for one [SatelliteTerrain]: one combined tier mesh
/// sampling one atlas texture. The atlas image and the GPU texture are
/// produced asynchronously; the frame renders an untextured drape until the
/// upload lands.
class _TerrainDrape {
  TerrainMeshSet? source;
  fs.MeshGeometry? drape;
  Future<fs.Texture2D>? textureFuture;
  fs.Texture2D? texture;
}

/// GPU terrain resources shared by every flight view. Building the drape
/// mesh and uploading the imagery per view mount — every workspace switch,
/// every extra tile — re-paid the full texture upload each time; sharing per
/// terrain makes a site's uploads happen once. The previous site stays alive
/// while a launchpad change settles; older sites drop out.
final Map<SatelliteTerrain, _TerrainDrape> _sharedTerrainDrapes = {};

/// Atlas texture uploads shared across all terrains: the progressive stages
/// rebuild the [SatelliteTerrain] around the same patch images, and without
/// this registry each stage would re-upload the atlas.
final Map<SatelliteTerrain, Future<fs.Texture2D>> _sharedTextureFutures = {};

/// Mirror through the world x=0 plane (the launch-site meridian), paired
/// with the mirrored engine camera in `_engineCamera`.
final vm.Matrix4 _mirrorTransform =
    vm.Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0);

class _EngineFlightGpuViewState extends State<_EngineFlightGpuView> {
  static const double _rocketScale = 0.8 / 2.15;

  late final fs.Scene _engineScene;

  fs.Geometry? _grid;
  ({double half, double step, double width})? _gridKey;
  fs.LineSegmentsGeometry? _trailLines;
  int _trailLineSegments = 0;
  double? _trailLineWidth;
  int? _trailFingerprint;
  fs.LineSegmentsGeometry? _dropLine;
  fs.MeshGeometry? _airframe;
  bool? _airframeNose;
  fs.MeshGeometry? _chute;

  // GPU drape of the terrain this view currently renders.
  _TerrainDrape? _activeDrape;
  SatelliteTerrain? _builtTerrain;
  TerrainMeshSet? _builtMeshSource;

  late final fs.Material _gridMaterial = fs.UnlitMaterial()
    ..baseColorFactor = vm.Vector4(0.42, 0.45, 0.5, 1.0)
    ..doubleSided = true;
  late final fs.Material _trailLineMaterial = fs.UnlitMaterial()
    ..baseColorFactor = toEngineColor(AppColors.seriesGpsTrack)
    ..doubleSided = true
    // Depth-tested lines still win over the terrain surface they ride on
    // (the clamped trail lies exactly on it); the small world-space lift is
    // invisible at flight scales.
    ..depthBias = 0.15;
  late final fs.Material _dropLineMaterial = fs.UnlitMaterial()
    ..baseColorFactor = toEngineColor(AppColors.mutedForeground)
    ..doubleSided = true
    ..depthBias = 0.15;
  late final fs.Material _rocketMaterial = fs.PhysicallyBasedMaterial()
    ..metallicFactor = 0.0
    ..roughnessFactor = 0.50;
  // Blob shadow: an opaque flat disc, deliberately NOT translucent. Both
  // the shadow and the terrain drape draw in the translucent pass sorted
  // by bounds-center depth, and against the single giant drape mesh that
  // order flips with the viewpoint: a translucent shadow is covered by the
  // drape whenever the drape sorts later, and a depth-writing one blends
  // over the not-yet-drawn terrain (sky/grid tones) whenever it sorts
  // first and then culls the drape. An opaque disc in the opaque pass is
  // correct in every order — like the trail and drop lines — at the price
  // of a hard edge. Double-sided disables culling so it also reads from
  // low grazing angles.
  late final fs.Material _shadowMaterial = fs.UnlitMaterial()
    ..baseColorFactor = vm.Vector4(0.08, 0.08, 0.08, 1.0)
    ..alphaMode = fs.AlphaMode.opaque
    ..doubleSided = true
    ..depthBias = 0.1;
  late final fs.Geometry _shadowDisk =
      fs.DiscGeometry(radius: 1.2, segments: 32);

  @override
  void initState() {
    super.initState();
    _engineScene = fs.Scene();
    _engineScene.skybox = fs.Skybox(_skySource());
    // Sun matching the terrain hillshade direction, mirrored into the
    // engine's frame like the camera (see `_engineCamera`).
    _engineScene.directionalLight = fs.DirectionalLight(
      direction:
          vm.Vector3(flightSunDir.x, -flightSunDir.y, -flightSunDir.z),
      intensity: 1.8,
    );
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
  /// with the camera; sized from the grid extents (whole flight in replay).
  ({double half, double step}) _gridExtents(FlightScene scene) {
    final gridHalf = math.min(
      10000.0,
      _niceCeil(math.max(60.0,
          math.max(scene.gridMaxHoriz * 1.3, scene.gridMaxAlt * 0.6))),
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

  /// Ribbon width in world metres that reads as roughly [px] screen pixels
  /// at [dist] metres (camera-facing ribbons are world-space width).
  /// Quantized to powers of 1.5 so zooming rebuilds line geometry rarely.
  double _lineWidthBucket(double dist, {required double px}) {
    final distBucket =
        math.pow(1.5, (math.log(dist) / math.log(1.5)).roundToDouble())
            .toDouble();
    return (px * 2 * math.tan(flightFovY / 2) * distBucket / 500)
        .clamp(0.02, 50.0);
  }

  /// Rebuilds the grid when the extents or the line-width bucket change. The
  /// width is keyed to the distance from the eye to the ground point under
  /// the target — the grid content the camera actually looks at — so the
  /// lines keep their screen thickness at every zoom.
  void _ensureGrid(FlightScene scene, double camDist) {
    final extents = _gridExtents(scene);
    final width = _lineWidthBucket(camDist, px: 1.5);
    if (_gridKey != null &&
        _gridKey!.half == extents.half &&
        _gridKey!.step == extents.step &&
        _gridKey!.width == width) {
      return;
    }
    _gridKey = (
      half: extents.half,
      step: extents.step,
      width: width,
    );
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
      width: width,
    );
  }

  /// GPS trail as depth-tested engine lines: the path correctly occludes
  /// behind the airframe and relief. Line ribbons are world-width, so the
  /// width scales with the camera distance (~2 px); rebuilt when the trail
  /// content (points move when the replay smoothing toggle flips) or the
  /// width bucket changes. Positions are x-negated (mirrored frame, see
  /// `_engineCamera`); the node lives outside the mirroring root like the
  /// grid.
  void _ensureTrailLines(FlightScene scene, double camDist) {
    if (scene.trail.length < 2) {
      _trailLines = null;
      _trailLineSegments = 0;
      _trailFingerprint = null;
      return;
    }
    final width = _lineWidthBucket(camDist, px: 2.0);
    final fingerprint = _trailFingerprintOf(scene.trail);
    if (_trailLines != null &&
        _trailLineSegments == scene.trail.length - 1 &&
        _trailLineWidth == width &&
        _trailFingerprint == fingerprint) {
      return;
    }
    _trailLineWidth = width;
    _trailFingerprint = fingerprint;
    _trailLineSegments = scene.trail.length - 1;
    final segments = Float32List(_trailLineSegments * 6);
    var o = 0;
    for (var i = 0; i + 1 < scene.trail.length; i++) {
      final a = scene.trail[i];
      final b = scene.trail[i + 1];
      segments[o++] = -a.x;
      segments[o++] = a.y;
      segments[o++] = a.z;
      segments[o++] = -b.x;
      segments[o++] = b.y;
      segments[o++] = b.z;
    }
    _trailLines = fs.LineSegmentsGeometry(
      fs.LineSegmentData(positions: segments),
      width: width,
    );
  }

  /// Cheap whole-content hash: the trail length alone cannot see point
  /// moves (replay smoothing reshapes the line without adding points).
  static int _trailFingerprintOf(List<vm64.Vector3> trail) {
    var h = trail.length;
    for (final p in trail) {
      h = h * 31 + p.x.hashCode;
      h = h * 31 + p.y.hashCode;
      h = h * 31 + p.z.hashCode;
    }
    return h;
  }

  /// Rocket→ground drop line as depth-tested engine geometry: it correctly
  /// hides behind the airframe while staying visible on the terrain surface
  /// (depth bias). Two vertices — rebuilt per frame. Mirrored frame, see
  /// `_engineCamera`.
  void _ensureDropLine(
    FlightScene scene,
    vm64.Vector3 anchor,
    double groundY,
    double camDist,
  ) {
    if (anchor.y - groundY < 0.05) {
      _dropLine = null;
      return;
    }
    _dropLine = fs.LineSegmentsGeometry(
      fs.LineSegmentData(positions: Float32List.fromList([
        -anchor.x, anchor.y, anchor.z, //
        -anchor.x, groundY, anchor.z, //
      ])),
      width: _lineWidthBucket(camDist, px: 1.2),
    );
  }

  void _ensureRocket(FlightScene scene) {
    if (_airframe == null || _airframeNose != scene.showNoseCone) {
      _airframeNose = scene.showNoseCone;
      final data = buildRocketGpuData(showNoseCone: scene.showNoseCone);
      _airframe = fs.MeshGeometry.fromArrays(
        positions: data.positions,
        normals: data.normals,
        colors: data.colors,
      );
    }
    if (scene.showParachute && _chute == null) {
      final chute = buildParachuteGpuData();
      _chute = fs.MeshGeometry.fromArrays(
        positions: chute.positions,
        normals: chute.normals,
        colors: chute.colors,
      );
    }
  }

  /// Points the view at the shared GPU drape for [terrain], building the
  /// combined tier mesh if the mesh set is new and starting the atlas
  /// upload if it has not landed yet.
  void _ensureTerrain(SatelliteTerrain? terrain, TerrainMeshSet? meshes) {
    if (terrain == null || meshes == null) {
      _activeDrape = null;
      _builtTerrain = null;
      _builtMeshSource = null;
      return;
    }
    if (identical(_builtTerrain, terrain) &&
        identical(_builtMeshSource, meshes)) {
      // A failed or interrupted atlas upload leaves the drape untextured;
      // retry on every build until the texture lands.
      final drape = _activeDrape;
      if (drape != null && drape.texture == null) {
        _ensureAtlasTexture(drape, terrain);
      }
      return;
    }
    _builtTerrain = terrain;
    _builtMeshSource = meshes;
    final drape =
        _sharedTerrainDrapes.putIfAbsent(terrain, _TerrainDrape.new);
    while (_sharedTerrainDrapes.length > 2) {
      _sharedTerrainDrapes.remove(_sharedTerrainDrapes.keys.first);
    }
    _activeDrape = drape;
    if (!identical(drape.source, meshes)) {
      drape.source = meshes;
      _rebuildDrapeMesh(drape, terrain, meshes);
    }
    _ensureAtlasTexture(drape, terrain);
  }

  /// Builds the combined tier mesh: outer context first, sharp pad last —
  /// the blend order the layered drape needs, baked into the index list.
  void _rebuildDrapeMesh(
    _TerrainDrape drape,
    SatelliteTerrain terrain,
    TerrainMeshSet meshes,
  ) {
    final tiers = <TerrainAtlasTier>[
      TerrainAtlasTier(
        mesh: meshes.outer,
        imageWidth: terrain.outer.image.width,
        imageHeight: terrain.outer.image.height,
        yOffset: outerTierLift,
      ),
      if (terrain.mid != null && meshes.mid != null)
        TerrainAtlasTier(
          mesh: meshes.mid!,
          imageWidth: terrain.mid!.image.width,
          imageHeight: terrain.mid!.image.height,
          yOffset: midTierLift,
        ),
      if (terrain.pad != null && meshes.pad != null)
        TerrainAtlasTier(
          mesh: meshes.pad!,
          imageWidth: terrain.pad!.image.width,
          imageHeight: terrain.pad!.image.height,
          yOffset: padTierLift,
        ),
    ];
    final data = buildTerrainAtlasGpuData(tiers: tiers, sunDir: terrainSunDir);
    drape.drape = fs.MeshGeometry.fromArrays(
      positions: data.positions,
      normals: data.normals,
      texCoords: data.texCoords,
      colors: data.colors,
      indices: data.indices,
    );
  }

  void _ensureAtlasTexture(_TerrainDrape drape, SatelliteTerrain terrain) {
    if (drape.textureFuture != null || drape.texture != null) return;
    final future = _sharedTextureFutures.putIfAbsent(
      terrain,
      () => _renderAtlasTexture(terrain),
    );
    while (_sharedTextureFutures.length > 4) {
      _sharedTextureFutures.remove(_sharedTextureFutures.keys.first);
    }
    drape.textureFuture = future;
    future.then((texture) {
      // Set on the shared drape regardless of this view's mount state, so
      // views mounting later see the texture.
      drape.texture = texture;
      if (mounted) setState(() {});
    }).catchError((Object _) {
      // Drop the failed upload so a later build can retry it.
      _sharedTextureFutures.remove(terrain);
      drape.textureFuture = null;
    });
  }

  /// Rasterizes the tier images into one vertical atlas and uploads it.
  Future<fs.Texture2D> _renderAtlasTexture(SatelliteTerrain terrain) async {
    final images = [
      terrain.outer.image,
      if (terrain.mid != null) terrain.mid!.image,
      if (terrain.pad != null) terrain.pad!.image,
    ];
    final width =
        images.map((i) => i.width).reduce((a, b) => a > b ? a : b);
    final height = images.fold(0, (sum, i) => sum + i.height);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    var y = 0.0;
    for (final image in images) {
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(
            0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(0, y, image.width.toDouble(), image.height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.none,
      );
      y += image.height;
    }
    final picture = recorder.endRecording();
    final atlas = await picture.toImage(width, height);
    picture.dispose();
    try {
      // No mip chain: Texture2D builds it synchronously on the UI isolate,
      // which stalled the app for seconds on the ~11-megapixel atlas, and
      // the engine exposes no async upload path.
      return await fs.Texture2D.fromImage(
        atlas,
        sampling: const fs.TextureSampling(mipmaps: false),
      );
    } finally {
      atlas.dispose();
    }
  }

  /// The scene with the rocket and trail clamped onto the DEM surface, plus
  /// the terrain height under the rocket.
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
    // flutter_scene's camera basis (right = up × forward) mirrors the frame
    // horizontally against the standard view matrix the lens and the 2D
    // overlay use, and its projection is built for that native frame —
    // feeding it the standard view instead breaks the near/depth mapping and
    // the frame renders empty. The mirror is cancelled by rendering the
    // scene from its mirror image: the content sits under a mirroring root
    // node (`_mirrorTransform`) and the camera is mirrored through the same
    // plane, which makes the engine produce the physically-correct image of
    // the original world that the overlay projects.
    return fs.PerspectiveCamera(
      fovRadiansY: cam.fovY,
      position: vm.Vector3(-cam.eye.x, cam.eye.y, cam.eye.z),
      target: vm.Vector3(-cam.target.x, cam.target.y, cam.target.z),
      up: vm.Vector3(-row.x, row.y, row.z),
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
    final pivot = vm64.Matrix4.translation(anchor) *
        vm64.Matrix4.fromList(m.storage) *
        vm64.Matrix4.translation(vm64.Vector3(0, -RocketMesh.cgY, 0));
    return vm.Matrix4.fromList(pivot.storage);
  }

  /// The canopy's mount: the popped tube mouth position, carried with the
  /// attitude so it stays attached to the airframe — the canopy itself is
  /// never tilted (its node has no rotation), so it always hangs world-up.
  /// Scaled 1.5x relative to the airframe.
  vm.Matrix4 _chuteTransform(FlightScene scene, vm64.Vector3 anchor) {
    final rocketM = _rocketTransform(scene, anchor);
    final mouth = vm64.Matrix4.fromList(rocketM.storage)
        .transformed3(vm64.Vector3(0, RocketMesh.bodyTop, 0));
    final chuteM = vm64.Matrix4.translation(mouth)
      ..scaleByDouble(
        _rocketScale * 1.5,
        _rocketScale * 1.5,
        _rocketScale * 1.5,
        1.0,
      );
    return vm.Matrix4.fromList(chuteM.storage);
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
        if (widget.showAirframe) _ensureRocket(scene);
        final drape = _activeDrape;
        final hasTerrain = drape?.drape != null;
        // Line widths key to the distance the camera actually looks at: the
        // ground point under the target for the grid (the rocket can ride
        // far above it), the target distance for the flight lines.
        final meshAnchor = _cgAnchor(scene, display.surfaceY);
        final gridDist = clamped.eye
            .distanceTo(vm64.Vector3(clamped.target.x, 0, clamped.target.z));
        final camDist = clamped.eye.distanceTo(clamped.target);
        if (!hasTerrain) _ensureGrid(scene, gridDist);
        _ensureTrailLines(scene, camDist);
        _ensureDropLine(scene, meshAnchor, display.surfaceY, camDist);
        final engineCamera = _engineCamera(clamped);

        // Meshes render under the mirroring root (paired with the mirrored
        // camera, see `_engineCamera`). The camera-facing line ribbons would
        // flip back-facing under the node mirror, so all line geometry stays
        // OUTSIDE it with x-negated positions: the grid is symmetric under
        // the x mirror, and the trail / drop line negate their x at build.
        // Lines depth-test against the meshes (see the line materials).
        // The blob shadow is an opaque flat disc mesh on the ground: it
        // depth-tests in the opaque pass like the trail lines, so ordering
        // against the translucent drape cannot affect it and the airframe
        // occludes it naturally.
        final showShadow = scene.rocketPos.y - display.surfaceY > 0.1;
        final mirrored = <Widget>[
          if (hasTerrain)
            fs.SceneMesh(
              geometry: drape!.drape!,
              material: _drapeMaterial(drape),
            ),
          if (showShadow)
            fs.SceneNode(
              transform: vm.Matrix4.translation(vm.Vector3(
                scene.rocketPos.x,
                display.surfaceY + 0.05,
                scene.rocketPos.z,
              )),
              children: [
                fs.SceneMesh(
                    geometry: _shadowDisk, material: _shadowMaterial),
              ],
            ),
          if (widget.showAirframe && _airframe != null)
            fs.SceneNode(
              transform: _rocketTransform(scene, meshAnchor),
              children: [
                fs.SceneMesh(geometry: _airframe!, material: _rocketMaterial),
              ],
            ),
          if (widget.showAirframe && scene.showParachute && _chute != null)
            fs.SceneNode(
              transform: _chuteTransform(scene, meshAnchor),
              children: [
                fs.SceneMesh(geometry: _chute!, material: _rocketMaterial),
              ],
            ),
        ];

        final children = <Widget>[
          fs.SceneNode(transform: _mirrorTransform, children: mirrored),
          if (!hasTerrain && _grid != null)
            fs.SceneMesh(geometry: _grid!, material: _gridMaterial),
          if (_trailLines != null)
            fs.SceneMesh(geometry: _trailLines!, material: _trailLineMaterial),
          if (_dropLine != null)
            fs.SceneMesh(geometry: _dropLine!, material: _dropLineMaterial),
        ];

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

  fs.Material _drapeMaterial(_TerrainDrape drape) {
    final material = fs.UnlitMaterial(
      colorTexture: drape.texture,
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
  final double under;
  final bool satTerrain;
  final bool vignette;

  _MarkerOverlayPainter({
    required this.scene,
    required this.cam,
    required this.anchor,
    required this.under,
    required this.satTerrain,
    required this.vignette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // World-space lines project past the frustum edges near the lens; keep
    // every mark inside the view bounds.
    canvas.clipRect(Offset.zero & size);
    paintLaunchSite(canvas, scene, cam.vp, size);
    paintDeadReckoning(
      canvas,
      scene,
      cam.vp,
      size,
      anchorOverride: anchor,
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
    if (!satTerrain) {
      final grid = flightGroundGrid(scene);
      paintGroundLabels(canvas, cam.vp, size, half: grid.half, step: grid.step);
      paintCompass(canvas, size, cam.view);
    }
    if (vignette) paintVignette(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _MarkerOverlayPainter old) =>
      !identical(old.scene, scene) ||
      !identical(old.cam, cam) ||
      old.under != under ||
      old.satTerrain != satTerrain ||
      old.vignette != vignette;
}
