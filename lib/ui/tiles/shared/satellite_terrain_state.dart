import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/replay_controller.dart';
import '../../../state/telemetry_provider.dart';
import '../../../state/telemetry_store.dart';
import './flight_scene_builder.dart';
import './satellite_ground.dart';

/// Progressive terrain fetch + retained drape mesh state shared by the
/// satellite-ground flight views (the 3D Flight tile and the Onboard camera
/// tile).
///
/// [resolveTerrainScene] resolves the terrain-grounded scene and anchor and,
/// as a side effect, starts or upgrades the terrain fetch and keeps the
/// retained meshes in sync. Callers paint with [terrain] and [terrainMeshes].
mixin SatelliteTerrainState<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
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

  /// Current terrain, or null while imageless (plain-ground fallback).
  SatelliteTerrain? get terrain => _terrain;

  /// Retained drape meshes for [terrain]; null together with it.
  TerrainMeshSet? get terrainMeshes => _meshes;

  /// Whether imagery is fetching or the retained meshes are still building
  /// (the view shows the plain ground plus a loading hint meanwhile).
  bool get terrainLoading =>
      (_terrain == null && _requestedKey != null) ||
      (_terrain != null && _meshes == null);

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
    fetchTerrainOuter(lat: anchor.lat, lon: anchor.lon).then((outer) {
      if (!mounted || _requestedKey != key || outer == null) return;
      _applyTerrain(key, SatelliteTerrain(outer: outer), 1);
    });
    Future.wait([
      fetchTerrainOuter(lat: anchor.lat, lon: anchor.lon),
      fetchTerrainMid(lat: anchor.lat, lon: anchor.lon),
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

  /// Resolves the terrain-grounded scene and anchor for the current
  /// providers, or `null` while frames/anchor are missing. Starts or
  /// upgrades the terrain fetch and syncs the retained meshes as side
  /// effects. Call once per build.
  ({FlightScene scene, FlightAnchor anchor})? resolveTerrainScene() {
    final state = ref.watch(telemetryStoreProvider);
    final site = ref.watch(effectiveLaunchSiteProvider);
    final replay = ref.watch(replayProvider);
    final connector = ref.watch(activeConnectorProvider);
    if (state.latest == null) return null;
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
    if (scene == null || anchor == null) return null;
    _ensurePatch(anchor);
    final anchorKey =
        '${anchor.lat.toStringAsFixed(4)},${anchor.lon.toStringAsFixed(4)}';
    if (!identical(_terrain, _meshTerrain) || _meshAnchorKey != anchorKey) {
      _meshTerrain = _terrain;
      _meshAnchorKey = anchorKey;
      // Plain-ground fallback while the retained meshes build off the build
      // path (they cost real CPU; building them inline froze the tile).
      _meshes = null;
      final terrain = _terrain;
      if (terrain != null) {
        cachedTerrainMeshes(
          terrain,
          lat0: anchor.lat,
          lon0: anchor.lon,
          cosLat0: anchor.cosLat,
        ).then((meshes) {
          if (!mounted ||
              _meshAnchorKey != anchorKey ||
              !identical(_terrain, terrain)) {
            return;
          }
          setState(() => _meshes = meshes);
        }).catchError((Object _) {
          // Keep the plain-ground fallback; a later stage retries.
        });
      }
    }
    return (scene: scene, anchor: anchor);
  }
}
