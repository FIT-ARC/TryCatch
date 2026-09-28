import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dead_reckoning/dead_reckoning.dart' show metresPerDegreeLat;
import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider;
import 'package:vector_math/vector_math_64.dart';

import '../../../core/elevation_math.dart'
    show demTileUrl, terrariumHeight;
import '../../../state/launch_site_store.dart' show LaunchSite;
import '../../../theme/app_colors.dart';
import './tile_io.dart';
import './slippy_math.dart';

/// Bridges theme colors into `dart:ui` paint code.
ui.Color _uiColor(ui.Color c) => ui.Color(c.toARGB32());

double _smoothstep(double t) => smoothstep(t);

/// Satellite imagery draped over the 3D flight views' ground plane.
///
/// Tiles come from the same Esri World Imagery source as the 2D map's
/// satellite layer (internet required); failures fall back to the plain
/// ground. Pure tile math is unit-tested; fetching/stitching is I/O.

/// Terrain surface height (m, same frame as the scene: true height above
/// the pad datum) under world ([eastM], [southM]). 0 without a DEM.
/// Pure — unit-tested.
double terrainSurfaceY(
  ElevationGrid? dem, {
  required double eastM,
  required double southM,
  required double lat0,
  required double lon0,
  required double cosLat0,
}) =>
    dem?.sampleRel(eastM, southM, lat0, lon0, cosLat0) ?? 0.0;

// ── Fetching & stitching ─────────────────────────────────────────────────────

/// One stitched satellite patch with exact geo bounds.
class SatellitePatch {
  final ui.Image image;
  final double northLat;
  final double southLat;
  final double westLon;
  final double eastLon;

  /// Half-extent (m) actually covered, for clamping the rendered area.
  final double coverageHalfMeters;

  /// Mean imagery color, so the procedural far terrain can pick up the local
  /// landscape (fields vs. city) instead of a flat grey.
  final ui.Color averageColor;

  const SatellitePatch({
    required this.image,
    required this.northLat,
    required this.southLat,
    required this.westLon,
    required this.eastLon,
    required this.coverageHalfMeters,
    required this.averageColor,
  });
}

/// Averages raw RGBA bytes (as from `Image.toByteData`) to one opaque color.
/// Pure — unit-tested. Falls back to a neutral sage on empty input.
ui.Color averageRgba(Uint8List bytes) {
  var r = 0, g = 0, b = 0, n = 0;
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    r += bytes[i];
    g += bytes[i + 1];
    b += bytes[i + 2];
    n++;
  }
  if (n == 0) return const ui.Color(0xFFB7BCAE);
  return ui.Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}

/// Mean color of [image], via a 48 px downscale so even a 9-tile stitch is
/// cheap to read back. Never throws — falls back to neutral sage.
Future<ui.Color> patchAverageColor(ui.Image image) async {
  try {
    const s = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, s, s),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final small = await picture.toImage(s.toInt(), s.toInt());
    picture.dispose();
    try {
      final data =
          await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return const ui.Color(0xFFB7BCAE);
      return averageRgba(data.buffer.asUint8List());
    } finally {
      small.dispose();
    }
  } catch (_) {
    return const ui.Color(0xFFB7BCAE);
  }
}

/// Fetches one tile's raw bytes (`null` on failure). Injectable for tests.
typedef SatTileFetcher = Future<Uint8List?> Function(Uri url);

/// Default fetcher: flutter_map's shared disk cache first (so settings'
/// "preload tiles" also warms the 3D satellite view, and vice versa), then
/// network with the result stored back. Esri "no data" placeholders are
/// treated as misses so the patch falls back to parent tiles.
Future<Uint8List?> _cachedFetcher(Uri url) async {
  final key = url.toString();
  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  if (cache.isSupported) {
    try {
      final hit = await cache.getTile(key);
      if (hit != null &&
          hit.bytes.isNotEmpty &&
          isUsableTileBytes(hit.bytes)) {
        return hit.bytes;
      }
    } catch (_) {
      // Corrupt entry — fall through to a fresh download below.
    }
  }
  final bytes = await fetchTileBytes(url);
  // Validate like the map precache does: HTML error pages must not poison
  // the shared cache (they fail image decode below, but would still store),
  // and neither must Esri's "Map data not yet available" placeholder tiles.
  if (bytes == null || !isUsableTileBytes(bytes)) return null;
  await putTileCached(key, bytes);
  return bytes;
}

String _key(double lat, double lon, double halfMeters) =>
    '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)},${halfMeters.toStringAsFixed(0)}';

final Map<String, Future<SatellitePatch?>> _patchCache = {};

/// Stitched Esri patch centred on [lat]/[lon] covering the fixed 20×20 km
/// terrain extent (plus margin). Cached by rounded centre; `null` when
/// offline or on any tile failure (callers fall back to plain ground).
/// Failures are NOT cached, so a later call retries instead of staying
/// blank for the session.
Future<SatellitePatch?> fetchSatellitePatch({
  required double lat,
  required double lon,
  SatTileFetcher fetcher = _cachedFetcher,
}) {
  final key = _key(lat, lon, satFixedHalfMeters);
  final hit = _patchCache[key];
  if (hit != null) return hit;
  final future = () async {
    try {
      return await _fetch(lat, lon, satFixedHalfMeters, fetcher);
    } catch (_) {
      return null;
    }
  }().then<SatellitePatch?>((patch) {
    if (patch == null) _patchCache.remove(key);
    return patch;
  });
  _patchCache[key] = future;
  return future;
}

/// Fetches tile (wx, y, zoom); when the server has no imagery at that level
/// (Esri caps rural areas around 17–18, or answers a "Map data not yet
/// available" placeholder which the fetcher reports as a miss), walks up to
/// [maxLevels] ancestors and returns the nearest usable one plus which cell
/// of it ([qx], [qy] in units of 2^(zoom-qz)) to crop. Returns `null` bytes
/// only when the whole chain fails.
Future<(Uint8List? bytes, int qx, int qy, int qz)> _fetchTileImage(
  SatTileFetcher fetcher,
  int wx,
  int y,
  int zoom, {
  int maxLevels = 3,
}) async {
  Uri url(int x, int y, int z) =>
      Uri.parse(satelliteTileUrl(x, y, z));
  final bytes = await fetcher(url(wx, y, zoom));
  if (bytes != null) return (bytes, 0, 0, zoom);
  for (var levels = 1; levels <= maxLevels; levels++) {
    final pz = zoom - levels;
    if (pz < 10) break;
    final n = 1 << pz;
    final px = ((wx >> levels) % n + n) % n;
    final py = (y >> levels).clamp(0, n - 1);
    final parent = await fetcher(url(px, py, pz));
    if (parent == null) continue;
    return (parent, wx - (px << levels), y - (py << levels), pz);
  }
  return (null, 0, 0, zoom);
}

/// Tile window (x, y, zoom triples) the imagery stitch fetches for
/// [halfMeters] at [targetPixels]/[maxTileRadius]. Pure — shared by the
/// fetcher and the offline precache so both agree on the URL set.
List<(int x, int y, int z)> satImageryWindow(
  double lat,
  double lon,
  double halfMeters, {
  required int targetPixels,
  required int maxTileRadius,
}) {
  final zoom =
      satZoomForHalfMeters(halfMeters, lat, targetPixels: targetPixels);
  final tileM = satMetresPerPixel(lat, zoom) * 256;
  final r = (halfMeters * 1.4 / tileM).ceil().clamp(1, maxTileRadius);
  final cx = satTileX(lon, zoom);
  final cy = satTileY(lat, zoom);
  final n = 1 << zoom;
  return [
    for (var y = math.max(0, cy - r);
        y <= math.min(n - 1, cy + r);
        y++)
      for (var x = cx - r; x <= cx + r; x++)
        (((x % n) + n) % n, y, zoom),
  ];
}

/// Tile window for the DEM fetch around [lat]/[lon]. Pure.
List<(int x, int y, int z)> satDemWindow(double lat, double lon) {
  const zoom = demZoom;
  const r = demTileRadius;
  final n = 1 << zoom;
  final cx = satTileX(lon, zoom);
  final cy = satTileY(lat, zoom);
  return [
    for (var y = math.max(0, cy - r);
        y <= math.min(n - 1, cy + r);
        y++)
      for (var x = cx - r; x <= cx + r; x++)
        (((x % n) + n) % n, y, zoom),
  ];
}

/// Every tile URL the fixed 20×20 km 3D terrain needs around [lat]/[lon]:
/// the outer, mid and pad imagery windows plus the DEM window. Pure —
/// feeds the offline precache (same disk cache the 3D view reads), so a
/// pre-downloaded site opens the satellite view instantly in the field.
List<String> satTerrainTileUrls(double lat, double lon) {
  final urls = <String>[];
  for (final (x, y, z) in satImageryWindow(lat, lon, satFixedHalfMeters,
      targetPixels: satOuterTargetPixels,
      maxTileRadius: satOuterTileRadius)) {
    urls.add(satelliteTileUrl(x, y, z));
  }
  for (final (x, y, z) in satImageryWindow(lat, lon, satMidHalfMeters,
      targetPixels: satMidTargetPixels,
      maxTileRadius: satMidTileRadius)) {
    urls.add(satelliteTileUrl(x, y, z));
  }
  for (final (x, y, z) in satImageryWindow(lat, lon, satPadHalfMeters,
      targetPixels: satPadTargetPixels,
      maxTileRadius: satPadTileRadius)) {
    urls.add(satelliteTileUrl(x, y, z));
  }
  for (final (x, y, z) in satDemWindow(lat, lon)) {
    urls.add(demTileUrl(x, y, z));
  }
  return urls.toSet().toList();
}

/// Stitched terrain: nested imagery tiers — [outer] context (up to 20×20
/// km), [mid] flight area (up to 10×10 km), [pad] sharp centre (2.5×2.5 km
/// at ~0.77 m/px) — plus an optional elevation grid. Painted back to front
/// with feathered rims, so tier seams cross-fade instead of drawing hard
/// crawl lines while panning. Mid/pad/dem are nullable to allow progressive
/// staging (outer first) and DEM failure; without a DEM the drape renders
/// flat like before.
class SatelliteTerrain {
  final SatellitePatch outer;
  final SatellitePatch? mid;
  final SatellitePatch? pad;

  /// Low-res elevation model for relief shading/displacement (`null` when
  /// the DEM fetch failed — the drape renders flat like before).
  final ElevationGrid? dem;

  const SatelliteTerrain(
      {required this.outer, this.mid, this.pad, this.dem});

  /// Mean imagery color for the procedural far terrain: prefer the
  /// sharpest tier present (what the camera actually looks at).
  ui.Color get averageColor =>
      pad?.averageColor ?? mid?.averageColor ?? outer.averageColor;
}

/// Whether a progressive terrain stage may replace the current display:
/// a new site always applies; for the same site only strict upgrades do —
/// never a downgrade or a stale re-arrival over what's showing (which
/// would read as the terrain flickering between flat and relief). Pure —
/// unit-tested.
bool shouldApplyTerrainStage({
  required String? currentKey,
  required int currentStage,
  required String key,
  required int stage,
}) {
  if (currentKey != key) return true;
  return stage > currentStage;
}

/// View-dependent emission order for one retained terrain tier.
///
/// `Canvas.drawVertices` has no depth buffer: overlapping triangles resolve
/// purely by draw order (later overwrites earlier), so a fixed north→south
/// grid order draws far hills over near ground from half of all viewing
/// directions. The painter must emit quads far-to-near along the view
/// direction instead.
///
/// [dirX]/[dirZ] is the horizontal view direction (target − eye): far means
/// +direction. Rows run north (j=0) → south, columns west (i=0) → east, so
/// looking north emits rows ascending, looking south descending; looking
/// east emits columns descending (east first), looking west ascending. The
/// dominant axis runs outermost so diagonal views stay close to true depth
/// order. Pure — unit-tested.
({bool jAsc, bool iEastFirst, bool outerIsJ}) terrainTierDrawOrder(
  double dirX,
  double dirZ,
) {
  return (
    jAsc: dirZ <= 0,
    iEastFirst: dirX > 0,
    outerIsJ: dirZ.abs() >= dirX.abs(),
  );
}

/// Grid resolutions (vertices per side) for the retained world-space
/// terrain meshes: coarse far context, medium flight area, dense pad
/// centre where the chase camera flies low. Built once per terrain —
/// frames only transform, never resample.
const int satMeshOuterRes = 80;
const int satMeshMidRes = 96;
const int satMeshPadRes = 160;

/// Far LOD for the pad centre (same extent/imagery as [satMeshPadRes]):
/// used while its quads are sub-pixel but the tier can't be skipped
/// outright — 4× fewer verts/tris per frame for an invisible delta.
const int satMeshPadFarRes = 80;

/// Distance fade for DEM displacement: full relief within
/// [demLiftFullMeters] of the anchor, fading to flat by
/// [demLiftFadeMeters] (far-field displacement swam while panning, so
/// only the near field bulges). Pure — unit-tested.
double demDistanceFade(double distM) {
  final lt = ((distM - demLiftFullMeters) /
          (demLiftFadeMeters - demLiftFullMeters))
      .clamp(0.0, 1.0);
  return 1 - lt * lt * (3 - 2 * lt);
}

/// One retained world-space drape tier: a regular grid over
/// [-half, +half]² metres (X east, Z south) around the anchor, with baked
/// DEM heights, imagery UVs (image pixels), surface normals, rim-feather
/// alphas, plus static triangle indices and prebuilt UV points.
///
/// Built once per terrain; per frame the painter only projects vertices
/// through the view-projection matrix, shades from the cached normals and
/// near-clips straddling triangles. Geometry is never recomputed from the
/// camera, so it cannot swim, pop or reshuffle while panning/zooming —
/// frames just rotate/scale/project the same mesh.
class TerrainMesh {
  final Float32List world;
  final Float32List normals;
  final Float32List alpha;
  final List<ui.Offset> uvPts;
  final List<int> indices;
  final int rows;
  final int cols;
  final double half;

  const TerrainMesh({
    required this.world,
    required this.normals,
    required this.alpha,
    required this.uvPts,
    required this.indices,
    required this.rows,
    required this.cols,
    required this.half,
  });

  int get vertexCount => rows * cols;
}

/// Retained meshes for every present tier of a terrain, plus the pad
/// tier's far LOD (see [satMeshPadFarRes]).
typedef TerrainMeshSet = ({
  TerrainMesh outer,
  TerrainMesh? mid,
  TerrainMesh? pad,
  TerrainMesh? padLo,
});

/// Builds one retained tier mesh over ±[halfMeters] around the anchor.
/// [imgW]/[imgH] are the imagery pixel dimensions (UVs are baked as
/// pixels, so frames never touch UV math). Pure — unit-tested.
TerrainMesh buildTerrainMesh({
  required double northLat,
  required double southLat,
  required double westLon,
  required double eastLon,
  required double imgW,
  required double imgH,
  required double coverageHalfMeters,
  required ElevationGrid? dem,
  required double lat0,
  required double lon0,
  required double cosLat0,
  required double halfMeters,
  required int resolution,
}) {
  final n = resolution;
  final world = Float32List(n * n * 3);
  final normals = Float32List(n * n * 3);
  final alpha = Float32List(n * n);
  final uvPts = <ui.Offset>[];
  for (var j = 0; j < n; j++) {
    final southM = -halfMeters + 2 * halfMeters * j / (n - 1);
    for (var i = 0; i < n; i++) {
      final eastM = -halfMeters + 2 * halfMeters * i / (n - 1);
      final k = j * n + i;
      final d = math.sqrt(eastM * eastM + southM * southM);
      final h = dem == null
          ? 0.0
          : dem.sampleRel(eastM, southM, lat0, lon0, cosLat0) *
              demDistanceFade(d);
      world[k * 3] = eastM;
      world[k * 3 + 1] = h;
      world[k * 3 + 2] = southM;
      final nrm = dem?.normalAt(eastM, southM, lat0, lon0, cosLat0);
      normals[k * 3] = nrm?.x ?? 0.0;
      normals[k * 3 + 1] = nrm?.y ?? 1.0;
      normals[k * 3 + 2] = nrm?.z ?? 0.0;
      final uvFrac = satUvFraction(
        eastM,
        southM,
        lat0,
        lon0,
        cosLat0,
        northLat: northLat,
        southLat: southLat,
        westLon: westLon,
        eastLon: eastLon,
      );
      final fade = satEdgeFade(uvFrac.u, uvFrac.v);
      alpha[k] = satRimAlpha(d, coverageHalfMeters) * fade;
      uvPts.add(ui.Offset(
        uvFrac.u.clamp(0.0, 1.0) * imgW,
        uvFrac.v.clamp(0.0, 1.0) * imgH,
      ));
    }
  }
  final indices = <int>[];
  for (var j = 0; j + 1 < n; j++) {
    for (var i = 0; i + 1 < n; i++) {
      final a = j * n + i;
      final b = a + 1;
      final c = a + n;
      final d2 = c + 1;
      indices.addAll([a, b, d2, a, d2, c]);
    }
  }
  return TerrainMesh(
    world: world,
    normals: normals,
    alpha: alpha,
    uvPts: uvPts,
    indices: indices,
    rows: n,
    cols: n,
    half: halfMeters,
  );
}

/// Builds retained meshes for every present tier of [terrain] around the
/// anchor (world origin). Reads patch bounds and image sizes only — never
/// pixels, so it stays cheap and synchronous.
TerrainMeshSet buildTerrainMeshes(
  SatelliteTerrain terrain, {
  required double lat0,
  required double lon0,
  required double cosLat0,
}) {
  TerrainMesh one(
    SatellitePatch patch,
    double halfMeters,
    int resolution,
  ) =>
      buildTerrainMesh(
        northLat: patch.northLat,
        southLat: patch.southLat,
        westLon: patch.westLon,
        eastLon: patch.eastLon,
        imgW: patch.image.width.toDouble(),
        imgH: patch.image.height.toDouble(),
        coverageHalfMeters: patch.coverageHalfMeters,
        dem: terrain.dem,
        lat0: lat0,
        lon0: lon0,
        cosLat0: cosLat0,
        halfMeters: halfMeters,
        resolution: resolution,
      );
  return (
    outer: one(terrain.outer, satFixedHalfMeters, satMeshOuterRes),
    mid: terrain.mid == null
        ? null
        : one(terrain.mid!, satMidHalfMeters, satMeshMidRes),
    pad: terrain.pad == null
        ? null
        : one(terrain.pad!, satPadHalfMeters, satMeshPadRes),
    padLo: terrain.pad == null
        ? null
        : one(terrain.pad!, satPadHalfMeters, satMeshPadFarRes),
  );
}

final Map<String, Future<SatelliteTerrain?>> _terrainCache = {};

final Map<String, Future<SatellitePatch?>> _outerCache = {};
final Map<String, Future<SatellitePatch?>> _midCache = {};
final Map<String, Future<SatellitePatch?>> _padCache = {};

/// Memory-cached single-tier fetch shared by the progressive stages and the
/// full fetch, so no stitch is ever built twice.
Future<SatellitePatch?> _cachedTier(
  Map<String, Future<SatellitePatch?>> cache,
  double lat,
  double lon,
  double halfMeters,
  SatTileFetcher fetcher, {
  required int targetPixels,
  required int maxTileRadius,
}) {
  final key = _key(lat, lon, halfMeters);
  final hit = cache[key];
  if (hit != null) return hit;
  final future = () async {
    try {
      return await _fetch(lat, lon, halfMeters, fetcher,
          targetPixels: targetPixels, maxTileRadius: maxTileRadius);
    } catch (_) {
      return null;
    }
  }().then<SatellitePatch?>((patch) {
    if (patch == null) cache.remove(key);
    return patch;
  });
  cache[key] = future;
  return future;
}

/// Fetches just the outer context patch (cached). The 3D view paints this
/// first for a fast first image, then upgrades through the mid tier to the
/// full [fetchSatelliteTerrain] (pad + DEM) as they land.
Future<SatellitePatch?> fetchTerrainOuter({
  required double lat,
  required double lon,
  SatTileFetcher fetcher = _cachedFetcher,
}) =>
    _cachedTier(_outerCache, lat, lon, satFixedHalfMeters, fetcher,
        targetPixels: satOuterTargetPixels,
        maxTileRadius: satOuterTileRadius);

/// Fetches just the mid flight-area tier (cached) — the second progressive
/// stage between [fetchTerrainOuter] and [fetchSatelliteTerrain].
Future<SatellitePatch?> fetchTerrainMid({
  required double lat,
  required double lon,
  SatTileFetcher fetcher = _cachedFetcher,
}) =>
    _cachedTier(_midCache, lat, lon, satMidHalfMeters, fetcher,
        targetPixels: satMidTargetPixels, maxTileRadius: satMidTileRadius);

/// Scene ground for the satellite tile: the DEM height at the pad once
/// elevation is in, so pad furniture sits exactly on the draped terrain
/// instead of floating above/below it on a stamp-vs-DEM disagreement.
/// Falls back to the configured site (map/sky stages before the DEM).
LaunchSite? resolveSceneSite(LaunchSite? site, ElevationGrid? dem) {
  if (site == null || dem == null) return site;
  return site.copyWith(altitudeMsl: dem.datumMsl);
}

/// Fetches the (cached) fixed three-tier terrain centred on [lat]/[lon]:
/// outer 20×20 km context, mid 10×10 km flight area, sharp 2.5×2.5 km pad
/// tier, plus the elevation grid. One key per site — the extent never grows
/// with the flight, so a flight triggers at most one stitch. `null` when
/// offline or on any tile failure (callers fall back to plain ground).
/// Failures are NOT cached, so a later call retries. Mid, pad and
/// elevation fetch concurrently with the outer patch so they never add
/// serial latency; pair with [fetchTerrainOuter]/[fetchTerrainMid] for a
/// progressive first paint (all stages share the tier caches).
///
/// [groundMslM] is the launch pad's MSL altitude: relief renders as true
/// height above the pad at 1:1 scale. When `null` (no site), relief falls
/// back to DEM-relative like before.
Future<SatelliteTerrain?> fetchSatelliteTerrain({
  required double lat,
  required double lon,
  double? groundMslM,
  SatTileFetcher fetcher = _cachedFetcher,
}) {
  final key = _key(lat, lon, satFixedHalfMeters);
  final hit = _terrainCache[key];
  if (hit != null) return hit;
  final future = () async {
    try {
      final outerFuture =
          fetchTerrainOuter(lat: lat, lon: lon, fetcher: fetcher);
      final midFuture =
          fetchTerrainMid(lat: lat, lon: lon, fetcher: fetcher);
      final padFuture = _cachedTier(
          _padCache, lat, lon, satPadHalfMeters, fetcher,
          targetPixels: satPadTargetPixels,
          maxTileRadius: satPadTileRadius);
      final demFuture = fetchDemGrid(
          lat: lat, lon: lon, groundMslM: groundMslM, fetcher: fetcher);
      final outer = await outerFuture;
      if (outer == null) return null;
      final mid = await midFuture;
      final pad = await padFuture;
      final dem = await demFuture;
      return SatelliteTerrain(outer: outer, mid: mid, pad: pad, dem: dem);
    } catch (_) {
      return null;
    }
  }().then<SatelliteTerrain?>((terrain) {
    if (terrain == null) _terrainCache.remove(key);
    return terrain;
  });
  _terrainCache[key] = future;
  return future;
}

// ── Elevation (Terrarium DEM relief) ─────────────────────────────────────────
// [demTileUrl]/[terrariumHeight] live in `core/elevation_math.dart` (single
// source, shared with the tile precache).

/// DEM zoom: z12 tiles are ~6.3 km wide at 50° latitude, so a 5×5 window
/// covers the whole 20 km terrain with margin.
const int demZoom = 12;

/// DEM tile radius: a (2×[demTileRadius]+1)² window around the centre.
const int demTileRadius = 2;

/// DEM grid cells per tile after downsampling (5×5 tiles → 160×160).
const int demCellPixels = 32;

/// Clamp for relative heights (m) — guards sea/void spikes.
const double demMaxReliefMeters = 400;

/// Step (m) for the hillshade central differences — matched to the DEM
/// posting (~200 m) so normals are smooth instead of facet-noisy. Smaller
/// steps sampled facet edges and made the shading shimmer while panning.
const double demNormalEps = 100.0;

/// DEM relief applies fully within [demLiftFullMeters] of the launch site
/// and fades out by [demLiftFadeMeters]. Far-field displacement is what
/// made the horizon swim: out there a pixel of camera motion swings the
/// ground hit across whole DEM posts, so lifted vertices jumped while
/// panning. Hillshading stays global (it varies smoothly); only the
/// geometric lift fades.
const double demLiftFullMeters = 3000;
const double demLiftFadeMeters = 8000;

/// Downsampled elevation grid (row 0 = north) backing drape displacement
/// and hillshading. Tiny (≈160×160 floats) and cached per launch site.
///
/// Relief is true height above [datumMsl] at 1:1 scale, so it agrees with
/// the rocket's baro-AGL altitude exactly. [datumMsl] is the launch pad's
/// MSL altitude when a site is configured (so surrounding hills sit at
/// their true height above the pad); without a site it falls back to the
/// DEM height at the grid centre (pad pinned to 0 like before).
class ElevationGrid {
  final double northLat;
  final double southLat;
  final double westLon;
  final double eastLon;
  final double datumMsl;
  final int cols;
  final int rows;
  final Float32List heights;

  /// Precomputed unit surface normals (3 floats per cell, X east / Y up /
  /// Z south), so per-frame hillshading is one bilinear sample instead of
  /// four height samples. `null` for hand-built grids (tests), which use
  /// the central-difference path in [normalAt].
  final Float32List? normals;

  const ElevationGrid({
    required this.northLat,
    required this.southLat,
    required this.westLon,
    required this.eastLon,
    required this.datumMsl,
    required this.cols,
    required this.rows,
    required this.heights,
    this.normals,
  });

  double _absAt(double u, double v) {
    final x = u * (cols - 1);
    final y = v * (rows - 1);
    final x0 = x.floor().clamp(0, cols - 1);
    final y0 = y.floor().clamp(0, rows - 1);
    final x1 = (x0 + 1).clamp(0, cols - 1);
    final y1 = (y0 + 1).clamp(0, rows - 1);
    final fx = (x - x0).clamp(0.0, 1.0);
    final fy = (y - y0).clamp(0.0, 1.0);
    final h00 = heights[y0 * cols + x0];
    final h10 = heights[y0 * cols + x1];
    final h01 = heights[y1 * cols + x0];
    final h11 = heights[y1 * cols + x1];
    return (h00 * (1 - fx) + h10 * fx) * (1 - fy) +
        (h01 * (1 - fx) + h11 * fx) * fy;
  }

  /// Bilinear height (m) above the launch pad datum, at true 1:1 scale and
  /// clamped. Returns 0 outside the grid and fades to 0 within 5% of the
  /// grid edge, so the drape settles onto the flat far terrain instead of
  /// ending in a relief cliff that would swim while panning. Pure.
  double sampleRel(
    double eastM,
    double southM,
    double lat0,
    double lon0,
    double cosLat0,
  ) {
    final lon = lon0 + eastM / (metresPerDegreeLat * cosLat0);
    final lat = lat0 - southM / metresPerDegreeLat;
    final spanLon = (eastLon - westLon).clamp(1e-12, 360.0);
    final spanLat = (northLat - southLat).clamp(1e-12, 180.0);
    final u = (lon - westLon) / spanLon;
    final v = (northLat - lat) / spanLat;
    if (u < 0 || u > 1 || v < 0 || v > 1) return 0;
    final edge = math.min(math.min(u, 1 - u), math.min(v, 1 - v));
    final fade = _smoothstep((edge / 0.05).clamp(0.0, 1.0));
    if (fade <= 0) return 0;
    final rel = (_absAt(u, v) - datumMsl) * fade;
    return rel.clamp(-demMaxReliefMeters, demMaxReliefMeters).toDouble();
  }

  /// Surface normal at ([eastM], [southM]), in world axes (X east, Y up,
  /// Z south). Prefers the precomputed [normals] grid (one bilinear
  /// sample); hand-built grids without it fall back to central differences
  /// ([demNormalEps] step). Pure.
  Vector3 normalAt(
    double eastM,
    double southM,
    double lat0,
    double lon0,
    double cosLat0,
  ) {
    final pre = normals;
    if (pre != null) {
      final lon = lon0 + eastM / (metresPerDegreeLat * cosLat0);
      final lat = lat0 - southM / metresPerDegreeLat;
      final spanLon = (eastLon - westLon).clamp(1e-12, 360.0);
      final spanLat = (northLat - southLat).clamp(1e-12, 180.0);
      final u = ((lon - westLon) / spanLon).clamp(0.0, 1.0);
      final v = ((northLat - lat) / spanLat).clamp(0.0, 1.0);
      final x = u * (cols - 1);
      final y = v * (rows - 1);
      final x0 = x.floor().clamp(0, cols - 1);
      final y0 = y.floor().clamp(0, rows - 1);
      final x1 = (x0 + 1).clamp(0, cols - 1);
      final y1 = (y0 + 1).clamp(0, rows - 1);
      final fx = (x - x0).clamp(0.0, 1.0);
      final fy = (y - y0).clamp(0.0, 1.0);
      var nx = 0.0, ny = 0.0, nz = 0.0;
      for (var j = 0; j < 2; j++) {
        final wy = j == 0 ? 1 - fy : fy;
        final r = (j == 0 ? y0 : y1) * cols;
        for (var i = 0; i < 2; i++) {
          final w = (i == 0 ? 1 - fx : fx) * wy;
          final c = (r + (i == 0 ? x0 : x1)) * 3;
          nx += pre[c] * w;
          ny += pre[c + 1] * w;
          nz += pre[c + 2] * w;
        }
      }
      final n = Vector3(nx, ny, nz);
      if (n.length2 > 1e-12) return n.normalized();
      return Vector3(0, 1, 0);
    }
    const eps = demNormalEps;
    final dhdx = (sampleRel(eastM + eps, southM, lat0, lon0, cosLat0) -
            sampleRel(eastM - eps, southM, lat0, lon0, cosLat0)) /
        (2 * eps);
    final dhdz = (sampleRel(eastM, southM + eps, lat0, lon0, cosLat0) -
            sampleRel(eastM, southM - eps, lat0, lon0, cosLat0)) /
        (2 * eps);
    return Vector3(-dhdx, 1, -dhdz).normalized();
  }

  /// Builds the per-cell unit-normal grid for [heights] over the given
  /// geo bounds (metres via [metresPerDegreeLat]). Pure — runs once per
  /// DEM fetch so frames never pay central differences.
  static Float32List buildNormals({
    required Float32List heights,
    required int cols,
    required int rows,
    required double northLat,
    required double southLat,
    required double westLon,
    required double eastLon,
  }) {
    final out = Float32List(cols * rows * 3);
    final midLat = (northLat + southLat) / 2;
    final gridWm = (eastLon - westLon) *
        metresPerDegreeLat *
        math.cos(midLat * math.pi / 180);
    final gridHm = (northLat - southLat) * metresPerDegreeLat;
    final cellW = gridWm / math.max(1, cols - 1);
    final cellH = gridHm / math.max(1, rows - 1);
    for (var j = 0; j < rows; j++) {
      final jm = math.max(0, j - 1);
      final jp = math.min(rows - 1, j + 1);
      for (var i = 0; i < cols; i++) {
        final im = math.max(0, i - 1);
        final ip = math.min(cols - 1, i + 1);
        final dhdx =
            (heights[j * cols + ip] - heights[j * cols + im]) /
                (math.max(1, ip - im) * cellW);
        final dhdz =
            (heights[jp * cols + i] - heights[jm * cols + i]) /
                (math.max(1, jp - jm) * cellH);
        final inv = 1 / math.sqrt(dhdx * dhdx + 1 + dhdz * dhdz);
        final c = (j * cols + i) * 3;
        out[c] = -dhdx * inv;
        out[c + 1] = inv;
        out[c + 2] = -dhdz * inv;
      }
    }
    return out;
  }
}

final Map<String, Future<ElevationGrid?>> _demCache = {};

/// Fetches a low-res DEM around [lat]/[lon] (z12 5×5 window, downsampled
/// to ~160×160). Cached per site + datum; `null` on any failure (callers
/// render flat). Failures are NOT cached.
///
/// [groundMslM] is the launch pad's MSL altitude and becomes the grid's
/// relief datum, so the drape renders at its true height above the pad.
/// When `null` (no configured site) the datum falls back to the DEM height
/// at the centre, pinning the pad to 0 like before.
Future<ElevationGrid?> fetchDemGrid({
  required double lat,
  required double lon,
  double? groundMslM,
  SatTileFetcher fetcher = _cachedFetcher,
}) {
  final key =
      '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)},${groundMslM?.toStringAsFixed(1) ?? 'dem'}';
  final hit = _demCache[key];
  if (hit != null) return hit;
  final future = () async {
    try {
      return await _fetchDem(lat, lon, fetcher, groundMslM);
    } catch (_) {
      return null;
    }
  }().then<ElevationGrid?>((grid) {
    if (grid == null) _demCache.remove(key);
    return grid;
  });
  _demCache[key] = future;
  return future;
}

Future<ElevationGrid?> _fetchDem(
  double lat,
  double lon,
  SatTileFetcher fetcher,
  double? groundMslM,
) async {
  const zoom = demZoom;
  const r = demTileRadius;
  final n = 1 << zoom;
  final cx = satTileX(lon, zoom);
  final cy = satTileY(lat, zoom);
  // Per-tile pixels after downsampling; 5×5 tiles → 160×160 grid.
  const cell = demCellPixels;
  const size = (2 * r + 1) * cell;
  final minY = math.max(0, cy - r);
  final maxY = math.min(n - 1, cy + r);

  // Tile bytes first, all at once: 25 sequential HTTP round-trips were the
  // bulk of DEM latency. S3 tolerates the burst; drawing stays ordered.
  final coords = <(int x, int y)>[
    for (var y = minY; y <= maxY; y++)
      for (var x = cx - r; x <= cx + r; x++) (x, y),
  ];
  final byteResults = await Future.wait([
    for (final (x, y) in coords)
      () async {
        final wx = ((x % n) + n) % n;
        return fetcher(Uri.parse(demTileUrl(wx, y, zoom)));
      }(),
  ]);
  final bytesByCoord = <(int, int), Uint8List?>{
    for (var i = 0; i < coords.length; i++) coords[i]: byteResults[i],
  };

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  var anyTile = false;
  for (final (x, y) in coords) {
    final bytes = bytesByCoord[(x, y)];
    if (bytes == null || !looksLikeImage(bytes)) continue;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final tile = frame.image;
      canvas.drawImageRect(
        tile,
        ui.Rect.fromLTWH(
            0, 0, tile.width.toDouble(), tile.height.toDouble()),
        ui.Rect.fromLTWH(
          (x - (cx - r)) * cell.toDouble(),
          (y - minY) * cell.toDouble(),
          cell.toDouble(),
          cell.toDouble(),
        ),
        ui.Paint()..filterQuality = ui.FilterQuality.low,
      );
      tile.dispose();
      anyTile = true;
    } catch (_) {
      // Skip undecodable tiles; neighbours interpolate over them.
    }
  }
  if (!anyTile) return null;
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  try {
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final px = data.buffer.asUint8List();
    final heights = Float32List(size * size);
    for (var i = 0; i < size * size; i++) {
      heights[i] = terrariumHeight(
          px[i * 4], px[i * 4 + 1], px[i * 4 + 2]);
    }
    final north = satTileLatNorth(minY, zoom);
    final south = satTileLatNorth(maxY + 1, zoom);
    final west = (cx - r) / (1 << zoom) * 360 - 180;
    final east = (cx + r + 1) / (1 << zoom) * 360 - 180;
    // Relief datum: the launch pad's MSL altitude when known, so the
    // drape sits at its true height above the pad; otherwise the DEM
    // height at the centre (pad pinned to 0). A DEM/site disagreement
    // then shows honestly as the pad terrain sitting slightly off y=0.
    var datumMsl = groundMslM;
    datumMsl ??= ElevationGrid(
      northLat: north,
      southLat: south,
      westLon: west,
      eastLon: east,
      datumMsl: 0,
      cols: size,
      rows: size,
      heights: heights,
    )._absAt(
      ((lon - west) / (east - west).clamp(1e-12, 360.0)),
      ((north - lat) / (north - south).clamp(1e-12, 180.0)),
    );
    return ElevationGrid(
      northLat: north,
      southLat: south,
      westLon: west,
      eastLon: east,
      datumMsl: datumMsl,
      cols: size,
      rows: size,
      heights: heights,
      normals: ElevationGrid.buildNormals(
        heights: heights,
        cols: size,
        rows: size,
        northLat: north,
        southLat: south,
        westLon: west,
        eastLon: east,
      ),
    );
  } finally {
    image.dispose();
  }
}

Future<SatellitePatch?> _fetch(
  double lat,
  double lon,
  double halfMeters,
  SatTileFetcher fetcher, {
  int targetPixels = 1024,
  int maxTileRadius = 2,
}) async {
  final zoom = satZoomForHalfMeters(halfMeters, lat,
      targetPixels: targetPixels);
  final mpp = satMetresPerPixel(lat, zoom);
  final tileM = mpp * 256;
  // Tile window around the centre, with margin for the scene plus label room.
  // Capped at (2*maxTileRadius+1)² tiles (9×9 = 2304 px at the terrain
  // radius 4): the far-terrain ring shows through outside instead of
  // growing the stitch without bound.
  final r =
      (halfMeters * 1.4 / tileM).ceil().clamp(1, maxTileRadius);
  final cx = satTileX(lon, zoom);
  final cy = satTileY(lat, zoom);
  final n = 1 << zoom;
  final minX = cx - r;
  final maxX = cx + r;
  final minY = math.max(0, cy - r);
  final maxY = math.min(n - 1, cy + r);

  final cols = maxX - minX + 1;
  final rows = maxY - minY + 1;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // Underlay in the surfaces voice so missing tiles read as unloaded
  // imagery (not a white hole) in both modes.
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, cols * 256, rows * 256),
    ui.Paint()..color = _uiColor(AppColors.muted),
  );

  var anyTile = false;
  // Fetch first with bounded parallelism, then decode in parallel batches,
  // then draw in tile order: sequential HTTP was the bulk of patch latency
  // (up to 81 tiles), and sequential codec work came second. 12 requests
  // in flight keeps tile servers happy.
  final coords = <(int x, int y)>[
    for (var y = minY; y <= maxY; y++)
      for (var x = minX; x <= maxX; x++) (x, y),
  ];
  final fetched = <(int, int), (Uint8List?, int, int, int)>{};
  const fetchConcurrency = 12;
  for (var i = 0; i < coords.length; i += fetchConcurrency) {
    final batch =
        coords.sublist(i, math.min(i + fetchConcurrency, coords.length));
    final results = await Future.wait([
      for (final (x, y) in batch)
        () async {
          // Wrap horizontally (tiles repeat around the antimeridian).
          final wx = ((x % n) + n) % n;
          final tile = await _fetchTileImage(fetcher, wx, y, zoom);
          return (x, y, tile);
        }(),
    ]);
    for (final (x, y, tile) in results) {
      fetched[(x, y)] = tile;
    }
  }
  // Parallel decode (CPU-bound); drawing below stays ordered. Holding the
  // decoded tiles costs ~21 MB transiently at 9×9.
  final images = <(int, int), ui.Image?>{};
  const decodeConcurrency = 8;
  final decodable = [
    for (final c in coords)
      if (fetched[c]?.$1 != null) c,
  ];
  for (var i = 0; i < decodable.length; i += decodeConcurrency) {
    final batch = decodable.sublist(
        i, math.min(i + decodeConcurrency, decodable.length));
    await Future.wait([
      for (final (x, y) in batch)
        () async {
          try {
            final codec =
                await ui.instantiateImageCodec(fetched[(x, y)]!.$1!);
            images[(x, y)] = (await codec.getNextFrame()).image;
          } catch (_) {
            // Skip undecodable tiles; the underlay shows through.
          }
        }(),
    ]);
  }
  for (final (x, y) in coords) {
    final tile = images[(x, y)];
    if (tile == null) continue;
    final (_, qx, qy, qz) = fetched[(x, y)]!;
    // Native tile: full image. Ancestor fallback: the cell we stand in
    // (2^(zoom-qz) split), upscaled to full size.
    final scale = qz == zoom ? 1 : 1 << (zoom - qz);
    final src = qz == zoom
        ? ui.Rect.fromLTWH(
            0, 0, tile.width.toDouble(), tile.height.toDouble())
        : ui.Rect.fromLTWH(
            qx * tile.width / scale,
            qy * tile.height / scale,
            tile.width / scale,
            tile.height / scale,
          );
    final dst = ui.Rect.fromLTWH(
      (x - minX) * 256.0,
      (y - minY) * 256.0,
      256.0,
      256.0,
    );
    canvas.drawImageRect(tile, src, dst, ui.Paint());
    tile.dispose();
    anyTile = true;
  }
  if (!anyTile) return null;

  final picture = recorder.endRecording();
  final image = await picture.toImage(cols * 256, rows * 256);
  picture.dispose();

  // Unwrapped edges keep the UV math continuous (antimeridian-safe); the
  // fetched tiles wrap, the bounds don't have to.
  final north = satTileLatNorth(minY, zoom);
  final south = satTileLatNorth(maxY + 1, zoom);
  final west = minX / (1 << zoom) * 360 - 180;
  final east = (maxX + 1) / (1 << zoom) * 360 - 180;
  final midLat = (north + south) / 2;
  final coverage = math.min(
        (north - south) * metresPerDegreeLat,
        (east - west) *
            metresPerDegreeLat *
            math.cos(midLat * math.pi / 180),
      ) /
      2;
  return SatellitePatch(
    image: image,
    northLat: north,
    southLat: south,
    westLon: west,
    eastLon: east,
    coverageHalfMeters: coverage,
    averageColor: await patchAverageColor(image),
  );
}
