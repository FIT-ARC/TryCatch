# 3D rendering — GPU only

All 3D tiles render through **Flutter GPU** via `flutter_scene` (Impeller).
There is no CPU fallback.

## Tiles

| Tile | View | Notes |
|---|---|---|
| 3D Rocket | `RocketGpuView` | airframe + parachute uploaded per nose-cone/parachute config; no zoom |
| Flight path | `FlightGpuView` (no terrain) | GPU grid + trail + drop line + airframe; labels and compass ride the overlay |
| 3D Flight | `FlightGpuView` + `SatelliteTerrain` | imagery atlas + DEM relief + 3D blob shadow |
| Onboard camera | `FlightGpuView` + `OnboardLens` | airframe hidden, glass vignette |

Geometry/stream builders live in `lib/ui/tiles/shared/gpu/`:

* `rocket_gpu_data.dart` — airframe and parachute conversion to GPU vertex
  streams with sRGB-to-linear albedo colors
  (`RocketMesh`/`ParachuteMesh`). Engine-free →
  `test/rocket_gpu_data_test.dart`.
* `terrain_gpu_data.dart` — retained `TerrainMesh` conversion into normalized
  UVs, baked hillshade RGB, radial feather alpha, plus the combined atlas
  mesh builder (`buildTerrainAtlasGpuData`). Engine-free →
  `test/terrain_gpu_data_test.dart`.
* `rocket_gpu_view.dart` — attitude node with mirror-composed transform;
  compass drawn as a 2D overlay through the standard view of the unmirrored
  camera.
* `flight_gpu_view.dart` — owns a `Scene` (procedural `GradientSkySource`
  skybox + directional sun matching the sky), drapes the terrain tiers
  (`UnlitMaterial`), draws the grid, GPS trail, drop line and 3D blob shadow
  on the ground (`LineSegmentsGeometry` and a flat disc mesh) and
  the CG-anchored airframe (`PhysicallyBasedMaterial`). World-space markers and
  HUD text ride the 2D overlay.

Camera/lens math is shared with the scene builder: `OrbitLens` / `OnboardLens`
(`flight_3d_common.dart`) compute the frame's `FlightCamera`, which is used both
for the engine camera and the overlay.

## Camera handedness

`flutter_scene` constructs its look-at basis as `right = up × forward`
(camera looking down +Z), whereas standard OpenGL camera projection uses
`right = up × backward` (camera looking down −Z). The views reconcile the two
by placing mesh content under a mirroring root node (`scale(-1, 1, 1)`) and
mirroring the engine camera through the same plane. The engine encoder
compensates the winding of mirrored subtrees, producing an unmirrored image
that aligns with the 2D overlay.

* Camera-facing ribbon geometries (the `LineSegmentsGeometry` family: grid,
  GPS trail, drop line) sit outside the mirror node to preserve ribbon
  facing. Their positions negate X at build time to align with the mirrored
  camera.
* The drape top side is wound to pass backface culling in
  `buildTerrainGpuData`.
* Single-sheet surfaces (`RocketMeshTri.noCull`, the parachute) emit mirrored
  twins in `buildParachuteGpuData` so they render from both sides. Shroud lines
  use crossed ribbons (tangent + radial) to remain visible from all angles.
* The parachute node translates to the popped tube mouth (transformed with the
  airframe's CG-anchored orientation) and scales at 1.5× relative to the
  airframe without applying body rotation, remaining upright at all attitudes.

Line ribbons carry world-space width scaled with the camera distance
(`_lineWidthBucket`, ~1.5–2 screen pixels, quantized to powers of 1.5). The
grid keys its width to the ground distance under the target. Trail and drop
lines write and test depth against the scene with a small `depthBias` so
ground-clamped lines remain visible over the terrain surface.

## Terrain loading and resources

Terrain processing runs off the UI thread and is cached per launch site:

* Imagery/DEM fetches are memory-cached per site in `satellite_ground.dart`.
* Retained `TerrainMeshSet` instances build on a background isolate via
  `cachedTerrainMeshes` (`compute(buildTerrainMeshesSpec, spec)`). While a job
  runs, tiles show the ground grid with a "Loading imagery…" overlay.
* The GPU drape (combined tier mesh + single atlas `Texture2D`) is cached per
  `SatelliteTerrain` in `flight_gpu_view.dart`. Atlas rasterization runs on the
  engine's raster thread and uploads without a mip chain to eliminate UI
  thread pauses.
* In replay mode, scene extents (`maxAlt`/`maxHoriz`) and camera framing
  follow the played flight history, while `gridMaxAlt`/`gridMaxHoriz` hold the
  full recording's bounds so the ground grid maintains its complete size from
  the start.

## Rendering paths

1. **flutter_scene (Flutter GPU)** renders all 3D scene elements: the PBR
   airframe, the unlit textured terrain drape, camera-facing ribbon lines
   (grid, GPS trail, drop line), the ground blob shadow (opaque flat disc,
   order-independent against the translucent drape), and the gradient skybox.
   Directional sunlight matches the terrain hillshade direction with
   intensity 1.8.
2. **2D `CustomPaint` overlay** clipped to the view bounds renders
   annotations through the shared `FlightCamera`: launch site flag, ground
   N/E labels, dead-reckoning connector/ring, under-ground badge, compass,
   vignette, and imagery attribution.
3. **flutter_map** renders the 2D map tile and satellite layer, sharing the
   tile disk cache with the 3D drape.

## Terrain details

* Tiers: outer 20×20 km, mid 10×10 km, pad 2.5×2.5 km. The GPU drape combines
  retained `TerrainMesh` tiers into a single mesh sampling a vertically-stacked
  atlas texture (`buildTerrainAtlasGpuData`). Tier draw order is sequential
  (outer, mid, pad).
* Per-vertex alpha applies a radial feather (`satRimAlpha`), opaque inside
  `satFeatherStart` of the tier radius and fading to zero at the imagery's
  boundary.
* Tiers share the ground DEM elevation without vertical offsets.
* Terrain material uses `UnlitMaterial` with `AlphaMode.blend`.
* Hillshade is baked per vertex from fixed sun direction `terrainSunDir`.

## Build requirements

* `windows/runner/main.cpp` calls `DartProject::set_enable_flutter_gpu(true)`;
  `linux/runner/my_application.cc` calls
  `fl_dart_project_set_enable_flutter_gpu(project, TRUE)`.
* `flutter config --enable-native-assets` (shader bundles).
* Impeller is the default desktop renderer on Flutter ≥ 3.47.
* Flutter **3.47.5 (stable)**, Dart 3.13. The `flutter_gpu_shaders` build hook
  recompiles bundles at build time with the SDK's `impellerc`.
