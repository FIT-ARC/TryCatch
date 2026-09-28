import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../../state/replay_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/flight_3d_shell.dart';
import './shared/orbit_camera.dart';
import './shared/rocket_mesh.dart';
import './shared/satellite_ground.dart';
import './shared/slippy_math.dart'
    show
        ClipVert,
        clipTriangleNear,
        drapeClipEps,
        lensFade,
        lensFadeStart,
        satMidHalfMeters;
import './shared/tile_io.dart';

/// 3D flight path over satellite imagery: the same scene, cameras and rocket
/// as [Flight3dTile], but the ground plane is textured with Esri World
/// Imagery around the launch site (the "Google Earth" view). Offline or
/// while tiles load it falls back to the plain ground.
///
/// Imagery covers a fixed 20×20 km around the launch site (nested outer /
/// mid / sharp-pad tiers plus true-scale DEM relief) and is cached per
/// site; offline or while tiles load it falls back to the plain ground.
class Flight3dSatelliteTile extends ConsumerStatefulWidget {
  const Flight3dSatelliteTile({super.key});

  @override
  ConsumerState<Flight3dSatelliteTile> createState() =>
      _Flight3dSatelliteWidgetState();
}

class _Flight3dSatelliteWidgetState
    extends ConsumerState<Flight3dSatelliteTile>
    with Flight3dShellState {
  /// Currently displayed terrain (kept across growth-triggered reloads).
  SatelliteTerrain? _terrain;

  /// Key + progressive stage of [_terrain] (1 outer, 2 +mid, 3 full).
  String? _terrainKey;
  int _terrainStage = 0;

  /// Imagery request already in flight, to size growth.
  String? _requestedKey;

  /// Retained world-space meshes for [_terrain], rebuilt only when the
  /// terrain object or anchor changes — never per frame. Frames only
  /// transform these (rotate/scale/project); geometry is camera-free.
  TerrainMeshSet? _meshes;
  SatelliteTerrain? _meshTerrain;
  String? _meshAnchorKey;

  /// Last imagery attempt (wall clock ms). While imageless, failed attempts
  /// back off so a dead network doesn't refire the tile burst every frame.
  int _lastPatchAttemptMs = 0;

  /// Applies a progressive stage unless a newer-or-equal stage for the same
  /// size is already showing (never downgrade warm-cache arrivals, never
  /// show a stale size over a current one — callers check [_requestedKey]).
  void _applyTerrain(String key, SatelliteTerrain terrain, int stage) {
    if (!shouldApplyTerrainStage(
      currentKey: _terrainKey,
      currentStage: _terrainStage,
      key: key,
      stage: stage,
    )) {
      return;
    }
    setState(() {
      _terrain = terrain;
      _terrainKey = key;
      _terrainStage = stage;
    });
  }

  void _ensurePatch(FlightAnchor anchor) {
    // Fixed 20×20 km terrain: one key per site, so a flight triggers at
    // most one stitch no matter how far it flies — never a reload mid-zoom.
    final key =
        '${anchor.lat.toStringAsFixed(4)},${anchor.lon.toStringAsFixed(4)}';
    if (key == _requestedKey) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // While imageless, back off after a failed attempt instead of refiring
    // the tile burst on every telemetry tick.
    if (_terrain == null && now - _lastPatchAttemptMs < 15000) return;
    _requestedKey = key;
    _lastPatchAttemptMs = now;
    // Progressive: the outer context patch paints first (one stitch), then
    // the mid tier, then the full terrain (sharp pad tier + DEM relief)
    // upgrades in place. Stages share the tier memory caches, so no stitch
    // is ever fetched or built twice.
    fetchTerrainOuter(
      lat: anchor.lat,
      lon: anchor.lon,
    ).then((outer) {
      if (!mounted || _requestedKey != key || outer == null) return;
      _applyTerrain(key, SatelliteTerrain(outer: outer), 1);
    });
    Future.wait([
      fetchTerrainOuter(
        lat: anchor.lat,
        lon: anchor.lon,
      ),
      fetchTerrainMid(
        lat: anchor.lat,
        lon: anchor.lon,
      ),
    ]).then((parts) {
      if (!mounted || _requestedKey != key) return;
      final outer = parts[0];
      final mid = parts[1];
      if (outer == null) return;
      _applyTerrain(key, SatelliteTerrain(outer: outer, mid: mid), 2);
    });
    fetchSatelliteTerrain(
      lat: anchor.lat,
      lon: anchor.lon,
      // No stamped datum: the grid centres itself on the DEM height at the
      // pad, so the draped terrain meets the pad furniture exactly instead
      // of floating above/below it on a stamp-vs-DEM disagreement.
      groundMslM: null,
    ).then((terrain) {
      if (!mounted) return;
      // Drop stale arrivals (a newer size was requested meanwhile).
      if (_requestedKey != key) return;
      if (terrain == null) {
        // Let a later build retry (subject to the backoff above).
        _requestedKey = null;
        return;
      }
      _applyTerrain(key, terrain, 3);
    });
  }

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

    // Replays render from the recording's full frames (whole flight
    // addressable, shared trail/rocket smoothing); live renders raw.
    // Airframe flags resolve with the active connector (auto-selected to
    // the recording's connector during playback).
    final connector = ref.watch(activeConnectorProvider);
    // Ground the scene on the terrain height at the pad once elevation is
    // in (same datum the drape uses, so furniture never floats); the
    // configured site before that.
    final sceneSite = resolveSceneSite(site, _terrain?.dem);
    final FlightScene? scene;
    if (replay.isActive && replay.frames.isNotEmpty) {
      scene = buildReplayScene(
        frames: replay.frames,
        positionMs: replay.positionMs,
        site: sceneSite,
        smoothingEnabled: replay.smoothingEnabled,
        connector: connector,
      );
    } else {
      scene = buildFlightScene(state, sceneSite, connector: connector);
    }
    final anchor = flightAnchor(state, sceneSite);
    if (scene == null || anchor == null) {
      return Center(child: WaitingForData());
    }
    // Onboard eases the strap-down attitude one tick (jitter melts, jumps
    // snap); every other mode renders the raw scene.
    final renderScene =
        mode == FlightCameraMode.onboard ? smoothOnboardScene(scene) : scene;
    _ensurePatch(anchor);

    final anchorKey =
        '${anchor.lat.toStringAsFixed(4)},${anchor.lon.toStringAsFixed(4)}';
    if (!identical(_terrain, _meshTerrain) || _meshAnchorKey != anchorKey) {
      _meshTerrain = _terrain;
      _meshAnchorKey = anchorKey;
      _meshes = _terrain == null
          ? null
          : buildTerrainMeshes(
              _terrain!,
              lat0: anchor.lat,
              lon0: anchor.lon,
              cosLat0: anchor.cosLat,
            );
    }

    return Flight3dShell(
      painter: SatFlightPainter(
        scene: renderScene,
        mode: mode,
        // Onboard spins locally around the long axis (strapped to the full
        // attitude, never the shared orbit angles, fixed down-tilt only);
        // every other mode shares one look direction.
        azimuthDeg: mode == FlightCameraMode.onboard
            ? onboardAzimuthDeg
            : camera.azimuthDeg,
        elevationDeg: mode == FlightCameraMode.onboard
            ? 0.0
            : camera.elevationDeg,
        zoom: zoom,
        terrain: _terrain,
        meshes: _meshes,
        anchor: anchor,
      ),
      mode: mode,
      onMode: setShellMode,
      onZoomBy: zoomBy,
      onResetZoom: resetZoom,
      onOrbit: orbitBy,
      extraOverlays: [
        if (_terrain != null)
          Positioned(
            right: 4,
            bottom: 2,
            child: Text(
              satelliteAttribution,
              style: TextStyle(
                fontSize: 9,
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

class SatFlightPainter extends CustomPainter {
  final FlightScene scene;
  final FlightCameraMode mode;
  final double azimuthDeg;
  final double elevationDeg;
  final double zoom;
  final SatelliteTerrain? terrain;

  /// Retained world-space meshes for [terrain] (built once in the widget
  /// state, projected here every frame). Null together with [terrain].
  final TerrainMeshSet? meshes;
  final FlightAnchor anchor;

  // Real-life scale: the mesh spans 2.15 model units for an ~80 cm airframe.
  static const double _rocketScale = 0.8 / 2.15;

  static Float32List _scratchCx = Float32List(0);
  static Float32List _scratchCy = Float32List(0);
  static Float32List _scratchCz = Float32List(0);
  static Float32List _scratchCw = Float32List(0);
  static Float32List _scratchShade = Float32List(0);

  // Scratch clip-space buffers are safe to share: they never escape into
  // engine objects (only read locally during emission). The `Vertices`
  // input lists below are deliberately per-call: sharing them across tiers
  // corrupts rendering (the engine must not see the same list object with
  // different content in one frame).

  /// Quantized hillshade×feather LUT (64 shade × 64 alpha): per-vertex
  /// `Color` allocation was ~40k objects/frame/tier. Steps (0.004 shade,
  /// 0.016 alpha) are invisible over busy imagery. Built once.
  static List<Color>? _shadeLut;

  /// Foreground gate for perspective subdivision (clip-space w ≈ metres
  /// down-view): only close triangles can span enough pixels for affine-UV
  /// warp to show. Distant steep-gradient tris skip subdivision entirely
  /// instead of quadrupling their upload.
  static const double _subdivMaxMinW = 150.0;

  static void _ensureScratch(int n) {
    if (_scratchCx.length < n) {
      _scratchCx = Float32List(n);
      _scratchCy = Float32List(n);
      _scratchCz = Float32List(n);
      _scratchCw = Float32List(n);
      _scratchShade = Float32List(n);
    }
  }

  SatFlightPainter({
    required this.scene,
    required this.mode,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.zoom,
    required this.terrain,
    required this.meshes,
    required this.anchor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);

    final aspect = size.width / math.max(1.0, size.height);
    // Terrain-relative flight path: the DEM surface — not the flat y=0
    // plane — is the ground truth here. Reported positions below the
    // surface (sensor noise, DEM/site mismatch) ride on top of it instead
    // of burying the airframe, and the badge reports by how much. The
    // display scene is built BEFORE the camera so chase/onboard views track
    // the clamped rocket — never the raw reported position.
    final dem = terrain?.dem;
    double surfaceAt(Vector3 p) => terrainSurfaceY(
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
        under > 0 ? Vector3(reported.x, surfaceY, reported.z) : reported;
    final clampedTrail = <Vector3>[];
    for (final p in scene.trail) {
      final s = surfaceAt(p);
      clampedTrail.add(s > p.y ? Vector3(p.x, s, p.z) : p);
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
    var cam = computeFlightCamera(
      scene: display,
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
      zoom: zoom,
      aspect: aspect,
    );
    // The lens itself must stay out of the hills too: a target on the
    // surface can still leave a low chase/onboard eye inside the next hill.
    cam = clampEyeAboveTerrain(
      cam,
      surfaceAt(Vector3(cam.eye.x, 0, cam.eye.z)) + 2.0,
    );

    paintSkyAndFarTerrain(canvas, size, cam,
        groundTint: terrain?.averageColor);
    if (terrain != null && meshes != null) {
      _paintMeshes(canvas, size, cam, meshes!, terrain!);
    } else {
      paintGroundPlain(canvas, display, cam.vp, size);
    }
    // Same CG pivot + trail-meets-middle treatment as the plain view,
    // against the terrain surface instead of the flat plane.
    final meshAnchor = cgAnchorPos(
      rocketPos: clampedPos,
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      scale: _rocketScale,
      groundY: surfaceY,
    );
    paintFlightTrail(canvas, display, cam.vp, size, tipOverride: meshAnchor);
    paintLaunchSite(canvas, display, cam.vp, size);
    // Shadow disk on the surface under the rocket, then the drop line to
    // the surface, then the hardware itself.
    paintShadowDisk(
      canvas,
      cam.vp,
      size,
      Vector3(clampedPos.x, surfaceY + 0.05, clampedPos.z),
      1.2,
    );
    paintDropLineAndDeadReckoning(canvas, display, cam.vp, size,
        anchorOverride: meshAnchor, groundY: surfaceY);
    if (under > 0.05) {
      paintUnderGroundLabel(
          canvas, cam.vp, size, meshAnchor, formatUnderMeters(under));
    }
    // Onboard the lens rides at the rocket looking to the side — the
    // airframe itself stays out of its own view.
    if (mode != FlightCameraMode.onboard) {
      paintRocketMesh(
        canvas,
        size,
        cam.vp,
        cam.view,
        cam.lightDir,
        rocketPos: meshAnchor,
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
    }
    // No compass gizmo here either — its N/E letters don't belong over imagery.
    // Lens glass last: the onboard vignette sits over the whole frame.
    if (mode == FlightCameraMode.onboard) paintVignette(canvas, size);
  }

  /// Drapes the satellite terrain from RETAINED world-space meshes (see
  /// [TerrainMesh]): geometry is built once per terrain around the anchor —
  /// baked DEM heights, imagery UVs, normals, feather alphas — and frames
  /// only transform it (project, shade, near-clip). Nothing is recomputed
  /// from the camera, so the ground cannot swim, pop or reshuffle while
  /// panning/zooming; every frame just rotates/scales/projects the same
  /// mesh.
  ///
  /// Nested tiers paint back to front — outer context (fixed 20×20 km),
  /// mid flight area, sharp pad centre — each with static rim feather
  /// into the layer below (and the outer into the far-terrain ring), so
  /// tier seams are world-fixed instead of crawling. Triangles straddling
  /// the near volume (lens plane + true near plane `z = -w`) clip via
  /// [clipTriangleNear] instead of dropping, so mountainsides stay
  /// continuous. Without a DEM the meshes are flat. The tessellated mesh
  /// is deliberate: DEM relief needs per-vertex heights, which 2D draw
  /// calls behind a `Canvas.transform` cannot carry (a perspective
  /// `Canvas.transform` itself paints fine — see
  /// `test/canvas_transform_probe_test.dart`). The imagery needs no grid
  /// lines.
  void _paintMeshes(Canvas canvas, Size size, FlightCamera cam,
      TerrainMeshSet meshes, SatelliteTerrain terrain) {
    // Back to front over the far-terrain underlay (painted by the caller):
    // static geometry means overdraw is blend-stable — the same world
    // triangles with the same alphas every frame.
    var painted = _paintMeshTier(canvas, size, cam, terrain.outer.image,
        meshes.outer, _tierQuadPx(cam, meshes.outer, size));
    final mid = terrain.mid;
    final midMesh = meshes.mid;
    if (mid != null && midMesh != null) {
      // Same sub-pixel rule as the pad tier: when zoomed out so far that a
      // mid quad covers < 0.5 px, the outer tier (which always spans the mid
      // extent, guarded by coverage below) already resolves it — skipping
      // ~18k triangles of pure overdraw. The pad tier is skipped likewise.
      final quadPx = _tierQuadPx(cam, midMesh, size);
      final outerCovers =
          terrain.outer.coverageHalfMeters >= satMidHalfMeters;
      if (quadPx >= 0.5 || !outerCovers) {
        painted = _paintMeshTier(canvas, size, cam, mid.image, midMesh,
                quadPx) ||
            painted;
      }
    }
    final pad = terrain.pad;
    final padMesh = meshes.pad;
    if (pad != null && padMesh != null) {
      // When zoomed out far away, each quad of the 160x160 pad mesh is sub-pixel.
      // If the mid tier is already present and covers this ground, skipping the
      // 51,200 pad triangles eliminates massive sub-pixel overdraw and hitching.
      final padQuadPx = _tierQuadPx(cam, padMesh, size);
      final skipPad = midMesh != null && padQuadPx < 0.85;
      if (!skipPad) {
        // Middle zone (sub-pixel but uncovered): the far LOD pad mesh has
        // 4× fewer verts/tris with quads still < 4 px — invisible delta.
        final lo = meshes.padLo;
        final useLo = lo != null && padQuadPx < 2.0;
        final chosen = useLo ? lo : padMesh;
        final chosenPx = useLo
            ? padQuadPx * (padMesh.cols - 1) / (lo.cols - 1)
            : padQuadPx;
        painted = _paintMeshTier(
                canvas, size, cam, pad.image, chosen, chosenPx) ||
            painted;
      }
    }
    if (!painted) {
      // Mesh squares cover ±10 km; outside them (or staring at the sky)
      // the far-terrain underlay behind is the ground. The plain grid is
      // a final backstop so the tile never goes blank.
      paintGroundPlain(canvas, scene, cam.vp, size);
    }
    // No N/E ground labels over imagery — the satellite view stays clean.
  }

  /// Screen size (px) of one mesh quad: drives the sub-pixel tier skips
  /// and the subdivision gate. Pure projection math, no allocation.
  static double _tierQuadPx(FlightCamera cam, TerrainMesh mesh, Size size) {
    final dist = cam.eye.distanceTo(Vector3(0, cam.target.y, 0));
    final quadM = mesh.half * 2 / (mesh.cols - 1);
    return (quadM / math.max(1.0, dist)) *
        (size.height / (2 * math.tan(cam.fovY / 2)));
  }

  /// Conservative whole-tier frustum test on the mesh bounding box
  /// (±[half] in X/Z, ±500 m in Y — relief is clamped to ±400 m): `false`
  /// only when every corner sits outside ONE frustum plane, so a visible
  /// tier can never be culled. Saves transforming + emitting up to 25.6k
  /// verts when a tier is entirely off-screen (sky stares, rear tiers).
  /// [m] is the column-major view-projection. No allocation.
  static bool _tierVisible(List<double> m, double half) {
    // Any corner at/behind the lens flips the projected inequalities, so
    // it forces "visible" (early return) — only fully-in-front boxes cull,
    // and only when every corner sits outside ONE frustum plane.
    var allNOut = true; // past the near plane (z + w <= 0)
    var allLOut = true; // left: x + w < 0
    var allROut = true; // right: w - x < 0
    var allBOut = true; // bottom: y + w < 0
    var allTOut = true; // top: w - y < 0
    for (var c = 0; c < 8; c++) {
      final x = (c & 1) == 0 ? -half : half;
      final y = (c & 2) == 0 ? -500.0 : 500.0;
      final z = (c & 4) == 0 ? -half : half;
      final cx = m[0] * x + m[4] * y + m[8] * z + m[12];
      final cy = m[1] * x + m[5] * y + m[9] * z + m[13];
      final cz = m[2] * x + m[6] * y + m[10] * z + m[14];
      final w = m[3] * x + m[7] * y + m[11] * z + m[15];
      // A corner at/behind the lens flips the projected inequalities, so
      // any such corner forces "visible" — only fully-in-front boxes cull.
      if (w <= drapeClipEps) return true;
      if ((cz + w) > drapeClipEps) allNOut = false;
      // w > eps here, so the x/w, y/w comparisons below are sound.
      if ((cx + w) >= -drapeClipEps) allLOut = false;
      if ((w - cx) >= -drapeClipEps) allROut = false;
      if ((cy + w) >= -drapeClipEps) allBOut = false;
      if ((w - cy) >= -drapeClipEps) allTOut = false;
      if (!allNOut &&
          !allLOut &&
          !allROut &&
          !allBOut &&
          !allTOut) {
        return true;
      }
    }
    return false;
  }

  /// Quantized hillshade tint from [_shadeLut] (see field docs).
  static Color _lutShade(double s, double a) {
    var lut = _shadeLut;
    if (lut == null) {
      lut = List<Color>.generate(
          4096, (k) => _shadeColor(0.72 + 0.28 * (k ~/ 64) / 63, (k % 64) / 63),
          growable: false);
      _shadeLut = lut;
    }
    var si = ((s - 0.72) * (63 / 0.28)).round();
    if (si < 0) {
      si = 0;
    } else if (si > 63) {
      si = 63;
    }
    var ai = (a * 63).round();
    if (ai < 0) {
      ai = 0;
    } else if (ai > 63) {
      ai = 63;
    }
    return lut[si * 64 + ai];
  }

  /// Projects one retained tier mesh and draws it. Per-vertex work per
  /// frame is one matrix transform plus one lighting dot — geometry, UVs,
  /// normals and alphas are baked and reused. Quads emit far-to-near along
  /// the view direction (see [terrainTierDrawOrder]): `drawVertices` has no
  /// depth buffer, so a fixed grid order lets far hills overwrite near
  /// ground from half of all viewing directions. Triangles straddling the
  /// near volume clip via [clipTriangleNear]. [quadPx] is this mesh's
  /// screen quad size (see [_tierQuadPx]): below 1 px subdivision is off
  /// (sub-pixel warp is invisible). Returns whether anything was drawn.
  /// After warmup the steady-state frame allocates nothing except the
  /// projected `Offset`s (required by `Vertices`), the engine upload copy,
  /// and rare near-plane clip verts.
  bool _paintMeshTier(
    Canvas canvas,
    Size size,
    FlightCamera cam,
    ui.Image img,
    TerrainMesh mesh,
    double quadPx,
  ) {
    final n = mesh.vertexCount;
    final world = mesh.world;
    final normals = mesh.normals;
    // Column-major view-projection: the transform loop allocates nothing.
    final m = cam.vp.storage;
    // Whole-tier frustum cull before touching any vertex: a fully
    // off-screen tier (sky stare, rear tier) emits nothing anyway.
    if (!_tierVisible(m, mesh.half)) return false;
    // Sub-pixel quads can't show affine-UV warp: skip the 4× subdivision
    // upload there (close foreground keeps it — see [needsSubdiv]).
    final allowSubdiv = quadPx >= 1.0;
    final lx = cam.lightDir.x;
    final ly = cam.lightDir.y;
    final lz = cam.lightDir.z;

    _ensureScratch(n);
    final cx = _scratchCx;
    final cy = _scratchCy;
    final cz = _scratchCz;
    final cw = _scratchCw;
    final shade = _scratchShade;

    // Per-tier frame lists: deliberately fresh every call (never shared
    // across tiers — the engine must not see the same list object with
    // different content in one frame). The baked mesh UVs pass through by
    // reference until the first clipped vert forces a copy (below).
    final positions = List<Offset>.filled(n, Offset.zero, growable: true);
    final colors =
        List<Color>.filled(n, const Color(0x00000000), growable: true);
    final meshUvs = mesh.uvPts;
    final meshAlpha = mesh.alpha;
    var uvs = meshUvs;
    final indices = <int>[];

    for (var k = 0; k < n; k++) {
      final x = world[k * 3];
      final y = world[k * 3 + 1];
      final z = world[k * 3 + 2];
      final cxk = m[0] * x + m[4] * y + m[8] * z + m[12];
      final cyk = m[1] * x + m[5] * y + m[9] * z + m[13];
      final czk = m[2] * x + m[6] * y + m[10] * z + m[14];
      final w = m[3] * x + m[7] * y + m[11] * z + m[15];
      cx[k] = cxk;
      cy[k] = cyk;
      cz[k] = czk;
      cw[k] = w;
      final s = 0.72 +
          0.28 *
              math.max(
                  0.0,
                  normals[k * 3] * lx +
                      normals[k * 3 + 1] * ly +
                      normals[k * 3 + 2] * lz);
      shade[k] = s;

      // True near-volume test (lens AND near plane): between-lens-and-near
      // verts must not project — their 1/w divide is what streaked. The
      // lens fade (see [lensFade]) dissolves sub-metre geometry instead
      // of smearing it across the frame.
      if (w > drapeClipEps && czk + w > drapeClipEps) {
        positions[k] = Offset(
          ((cxk / w * 0.5 + 0.5) * size.width)
              .clamp(-4000.0, size.width + 4000.0),
          ((0.5 - cyk / w * 0.5) * size.height)
              .clamp(-4000.0, size.height + 4000.0),
        );
        colors[k] = _lutShade(s, meshAlpha[k] * lensFade(w));
      }
    }

    final rightEdge = size.width;
    final bottomEdge = size.height;

    int addClippedVert(ClipVert v) {
      if (identical(uvs, meshUvs)) {
        uvs = List<Offset>.from(meshUvs, growable: true);
      }
      final idx = positions.length;
      final w = v.c.w;
      positions.add(Offset(
        ((v.c.x / w * 0.5 + 0.5) * size.width)
            .clamp(-4000.0, rightEdge + 4000.0),
        ((0.5 - v.c.y / w * 0.5) * size.height)
            .clamp(-4000.0, bottomEdge + 4000.0),
      ));
      uvs.add(Offset(v.u, v.v));
      colors.add(_lutShade(v.shade, v.alpha * lensFade(v.c.w)));
      return idx;
    }

    ClipVert vert(int k) => (
          c: Vector4(cx[k], cy[k], cz[k], cw[k]),
          u: meshUvs[k].dx,
          v: meshUvs[k].dy,
          shade: shade[k],
          alpha: meshAlpha[k],
        );

    final rows = mesh.rows;
    final cols = mesh.cols;
    final vx = cam.target.x - cam.eye.x;
    final vz = cam.target.z - cam.eye.z;
    final order = terrainTierDrawOrder(vx, vz);

    ClipVert lerpClipVert(ClipVert v0, ClipVert v1, double t) => (
          c: v0.c * (1 - t) + v1.c * t,
          u: v0.u + (v1.u - v0.u) * t,
          v: v0.v + (v1.v - v0.v) * t,
          shade: v0.shade + (v1.shade - v0.shade) * t,
          alpha: v0.alpha + (v1.alpha - v0.alpha) * t,
        );

    // In front of the near volume (lens AND true near plane — see the
    // transform loop): between-lens-and-near corners must clip, not project.
    bool front(int k) =>
        cw[k] > drapeClipEps && cz[k] + cw[k] > drapeClipEps;

    // Whether perspective subdivision can pay off for this triangle:
    // steep depth gradient AND close enough to span pixels (see
    // [_subdivMaxMinW]) AND this tier isn't sub-pixel ([allowSubdiv]).
    // Otherwise one affine-mapped triangle — invisible warp, 4× less
    // upload.
    bool needsSubdiv(double minW, double maxW) =>
        allowSubdiv && maxW > minW * 1.5 && minW < _subdivMaxMinW;

    // Adaptively subdivides foreground triangles whose depth gradient is
    // steep (maxW / minW > 1.5). Because Canvas.drawVertices interpolates
    // UVs affinely across each triangle in 2D screen space, large
    // foreground triangles at grazing angles warp along the diagonal seam
    // without perspective division. Subdividing in 4D clip space places
    // internal vertices at their exact perspective-correct screen
    // positions, eliminating foreground texture warping.
    void emitSubdividedTri(ClipVert v0, ClipVert v1, ClipVert v2, int depth) {
      // Lens-fade drop (see [lensFade]): fully faded sub-tris are
      // invisible — prune them instead of uploading transparent geometry.
      if (v0.c.w <= lensFadeStart &&
          v1.c.w <= lensFadeStart &&
          v2.c.w <= lensFadeStart) {
        return;
      }
      final w0 = v0.c.w;
      final w1 = v1.c.w;
      final w2 = v2.c.w;
      final minW = math.min(w0, math.min(w1, w2));
      final maxW = math.max(w0, math.max(w1, w2));

      if (depth > 0 && needsSubdiv(minW, maxW)) {
        final m01 = lerpClipVert(v0, v1, 0.5);
        final m12 = lerpClipVert(v1, v2, 0.5);
        final m20 = lerpClipVert(v2, v0, 0.5);
        emitSubdividedTri(v0, m01, m20, depth - 1);
        emitSubdividedTri(m01, v1, m12, depth - 1);
        emitSubdividedTri(m20, m12, v2, depth - 1);
        emitSubdividedTri(m01, m12, m20, depth - 1);
        return;
      }

      final i0 = addClippedVert(v0);
      final i1 = addClippedVert(v1);
      final i2 = addClippedVert(v2);
      indices
        ..add(i0)
        ..add(i1)
        ..add(i2);
    }

    void emitTri(int a, int b, int c) {
      if (meshAlpha[a] <= 0 && meshAlpha[b] <= 0 && meshAlpha[c] <= 0) {
        return;
      }
      final fa = front(a);
      final fb = front(b);
      final fc = front(c);
      // Fully outside the near volume: drop before building any clip
      // verts (partial quads reach here per-triangle via [emitQuad]).
      if (!fa && !fb && !fc) return;
      // Fully inside the lens-fade band (see [lensFade]): all three verts
      // fade to exactly 0, so the tri is invisible — drop it before it can
      // smear (this is the buried-camera case: relief centimetres from the
      // lens would otherwise cover the frame with minified texture).
      if (cw[a] <= lensFadeStart &&
          cw[b] <= lensFadeStart &&
          cw[c] <= lensFadeStart) {
        return;
      }
      if (fa && fb && fc) {
        final wa = cw[a];
        final wb = cw[b];
        final wc = cw[c];
        final minW = math.min(wa, math.min(wb, wc));
        final maxW = math.max(wa, math.max(wb, wc));
        if (needsSubdiv(minW, maxW)) {
          emitSubdividedTri(vert(a), vert(b), vert(c), 2);
        } else {
          indices
            ..add(a)
            ..add(b)
            ..add(c);
        }
      } else {
        final clipped = clipTriangleNear(vert(a), vert(b), vert(c));
        if (clipped.length < 3) return;
        for (var i = 1; i + 1 < clipped.length; i++) {
          final v0 = clipped[0];
          final v1 = clipped[i];
          final v2 = clipped[i + 1];
          // Same lens-fade drop as above, for clipped slivers hugging the
          // lens (crossings pin at w≈eps, i.e. fully faded).
          if (v0.c.w <= lensFadeStart &&
              v1.c.w <= lensFadeStart &&
              v2.c.w <= lensFadeStart) {
            continue;
          }
          final minW = math.min(v0.c.w, math.min(v1.c.w, v2.c.w));
          final maxW = math.max(v0.c.w, math.max(v1.c.w, v2.c.w));
          if (needsSubdiv(minW, maxW)) {
            emitSubdividedTri(v0, v1, v2, 2);
          } else {
            final i0 = addClippedVert(v0);
            final i1 = addClippedVert(v1);
            final i2 = addClippedVert(v2);
            indices
              ..add(i0)
              ..add(i1)
              ..add(i2);
          }
        }
      }
    }

    void emitQuad(int j, int i) {
      final a = j * cols + i;
      final b = a + 1;
      final c = a + cols;
      final d = c + 1;
      if (meshAlpha[a] <= 0 &&
          meshAlpha[b] <= 0 &&
          meshAlpha[c] <= 0 &&
          meshAlpha[d] <= 0) {
        return;
      }
      final wa = cw[a];
      final wb = cw[b];
      final wc = cw[c];
      final wd = cw[d];
      final fa = wa > drapeClipEps && cz[a] + wa > drapeClipEps;
      final fb = wb > drapeClipEps && cz[b] + wb > drapeClipEps;
      final fc = wc > drapeClipEps && cz[c] + wc > drapeClipEps;
      final fd = wd > drapeClipEps && cz[d] + wd > drapeClipEps;
      if (fa && fb && fc && fd) {
        final pa = positions[a];
        final pb = positions[b];
        final pc = positions[c];
        final pd = positions[d];
        if (pa.dx < 0 && pb.dx < 0 && pc.dx < 0 && pd.dx < 0) return;
        if (pa.dx > size.width &&
            pb.dx > size.width &&
            pc.dx > size.width &&
            pd.dx > size.width) {
          return;
        }
        if (pa.dy < 0 && pb.dy < 0 && pc.dy < 0 && pd.dy < 0) return;
        if (pa.dy > size.height &&
            pb.dy > size.height &&
            pc.dy > size.height &&
            pd.dy > size.height) {
          return;
        }
      } else if (!fa && !fb && !fc && !fd) {
        return;
      }
      emitTri(a, b, d);
      emitTri(a, d, c);
    }

    if (order.outerIsJ) {
      if (order.jAsc) {
        for (var j = 0; j + 1 < rows; j++) {
          if (order.iEastFirst) {
            for (var i = cols - 2; i >= 0; i--) {
              emitQuad(j, i);
            }
          } else {
            for (var i = 0; i + 1 < cols; i++) {
              emitQuad(j, i);
            }
          }
        }
      } else {
        for (var j = rows - 2; j >= 0; j--) {
          if (order.iEastFirst) {
            for (var i = cols - 2; i >= 0; i--) {
              emitQuad(j, i);
            }
          } else {
            for (var i = 0; i + 1 < cols; i++) {
              emitQuad(j, i);
            }
          }
        }
      }
    } else {
      if (order.iEastFirst) {
        for (var i = cols - 2; i >= 0; i--) {
          if (order.jAsc) {
            for (var j = 0; j + 1 < rows; j++) {
              emitQuad(j, i);
            }
          } else {
            for (var j = rows - 2; j >= 0; j--) {
              emitQuad(j, i);
            }
          }
        }
      } else {
        for (var i = 0; i + 1 < cols; i++) {
          if (order.jAsc) {
            for (var j = 0; j + 1 < rows; j++) {
              emitQuad(j, i);
            }
          } else {
            for (var j = rows - 2; j >= 0; j--) {
              emitQuad(j, i);
            }
          }
        }
      }
    }
    assert(() {
      // Retained topology check: every grid quad emits exactly once.
      final quads = (rows - 1) * (cols - 1);
      return mesh.indices.length == quads * 6;
    }());

    if (indices.isEmpty) return false;
    final paint = Paint()
      ..shader = ui.ImageShader(
        img,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        Matrix4.identity().storage,
      );
    canvas.drawVertices(
      ui.Vertices(
        ui.VertexMode.triangles,
        positions,
        // No clip/subdiv overflow: the baked mesh UVs go in directly
        // (zero copy — [addClippedVert] copies on first overflow instead).
        textureCoordinates: uvs,
        colors: colors,
        indices: indices,
      ),
      ui.BlendMode.modulate,
      paint,
    );
    return true;
  }

  /// Grayscale vertex tint for hillshading (modulated over the imagery),
  /// with the rim-feather alpha so tiers cross-fade into the layer below.
  static Color _shadeColor(double b, double a) {
    final v = (255 * b.clamp(0.0, 1.0)).round().clamp(0, 255);
    final alpha = (255 * a.clamp(0.0, 1.0)).round().clamp(0, 255);
    return Color.fromARGB(alpha, v, v, v);
  }

  @override
  bool shouldRepaint(covariant SatFlightPainter old) =>
      !identical(old.scene, scene) ||
      old.mode != mode ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.zoom != zoom ||
      old.terrain != terrain ||
      !identical(old.meshes, meshes) ||
      old.anchor != anchor;
}

