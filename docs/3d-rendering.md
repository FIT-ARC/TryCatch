# 3D rendering — GPU only

All 3D tiles render through **Flutter GPU** via `flutter_scene` (Impeller).
There is no CPU fallback.

## Tiles

| Tile | View | Notes |
|---|---|---|
| 3D Rocket | `RocketGpuView` | airframe uploaded once per nose-cone/parachute config |
| Flight path | `FlightGpuView` (no terrain) | GPU grid + trail + airframe |
| 3D Flight | `FlightGpuView` + `SatelliteTerrain` | imagery textures + DEM meshes |
| Onboard camera | `FlightGpuView` + `OnboardLens` | airframe hidden, glass vignette |

Geometry/stream builders live in `lib/ui/tiles/shared/gpu/`:

* `rocket_gpu_data.dart` — pure airframe → positions/normals/colors
  (`RocketMesh`/`ParachuteMesh`). Engine-free → `test/rocket_gpu_data_test.dart`.
* `terrain_gpu_data.dart` — pure retained `TerrainMesh` → normalized UVs,
  baked hillshade RGB, feather alpha, per-tier Y lift. Engine-free →
  `test/terrain_gpu_data_test.dart`.
* `rocket_gpu_view.dart` — attitude node + `PerspectiveCamera`; compass drawn
  as a 2D overlay through the engine camera's view matrix.
* `flight_gpu_view.dart` — owns a `Scene` (procedural `GradientSkySource`
  skybox), drapes the terrain tiers (`UnlitMaterial`, per-vertex shade ×
  feather alpha), draws the grid (`LineSegmentsGeometry`, one instanced draw),
  the trail (`PolylineGeometry`, screen-pixel width) and the CG-anchored
  airframe (`PhysicallyBasedMaterial`).

Camera/lens math is shared with the scene builder: `OrbitLens` / `OnboardLens`
(`flight_3d_common.dart`) compute the frame's `FlightCamera`, which is used both
for the engine camera and the overlay, so nothing can disagree.

## Overlays (2D, on purpose)

World-space annotations and screen-space chrome ride a thin `CustomPainter`
over the GPU frame, reusing the same camera and the tested helpers: launch-site
flag, rocket drop line, dead-reckoning connector/ring, shadow disk,
under-ground badge, compass, onboard vignette, imagery attribution. These are
vector/text annotations, not the 3D scene.

## Terrain details

* Tiers: outer 20×20 km, mid 10×10 km, pad 2.5×2.5 km. Each tier is a retained
  `TerrainMesh` (from `satellite_ground.dart`) converted to a GPU mesh with a
  `Texture2D` upload of its stitched imagery.
* Tier Y lift (`padTierLift` / `midTierLift` / `outerTierLift`, centimetres)
  keeps the blended, nearly coplanar tiers from z-fighting under the depth
  buffer.
* Terrain material is `UnlitMaterial` with `AlphaMode.blend`; the unlit shader
  computes `alpha = base.a * vertex_color.a * color.a`, so the baked feather
  alpha cross-fades tier rims.
* Hillshade is baked per vertex from a fixed sun (`terrainSunDir`), keeping the
  drape camera-independent.

## Build requirements

* `windows/runner/main.cpp` calls `DartProject::set_enable_flutter_gpu(true)`;
  `linux/runner/my_application.cc` calls
  `fl_dart_project_set_enable_flutter_gpu(project, TRUE)`.
* `flutter config --enable-native-assets` (shader bundles).
* Impeller is the default desktop renderer on Flutter ≥ 3.47; `flutter_scene`
  is pre-1.0 and can carry breaking changes in minor releases.

### Shader bundles vs the engine (the v1/v2 trap) ⚠️

The engine loads `flutter_scene`'s base/physical shader bundles and rejects
any whose flatbuffer `format_version` differs from its own
(`Unsupported shader bundle format version: 1, expected: 2`). The format was
bumped 1 → 2 on 2026-05-01 (flutter #185879). The bundles are not shipped
matching the engine — the `flutter_gpu_shaders` build hook recompiles them
at build time with the SDK's `impellerc`, so **the hook's compiler must come
from the same SDK build as the engine that runs the app.**

Gotcha: `findImpellerC()` probes artifact dirs in a fixed order
(`darwin-x64`, `linux-*`, **`windows-x64`**, `windows-arm64`) and this ARM64
machine had a stale `windows-x64/impellerc.exe` (May 2026, pre-bump → emits
v1) shadowing the fresh ARM64 one — so every rebuild silently produced v1
bundles that the v2-expecting engine rejected. Fixed by moving the stale
binary aside (`bin/cache/artifacts/engine/windows-x64/impellerc.exe.stale-v1`).
If the error ever returns: check which impellerc the hook picks
(`dart run` logging prints the resolved path), compare its emitted bundle's
`format_version` (uint32 field at flatbuffer vtable slot 6) against the
running engine's expectation, and delete/refresh stale
`bin/cache/artifacts/engine/*/impellerc.*`. After changing compilers, wipe
`.dart_tool/hooks_runner` and `.dart_tool/flutter_build` — the build caches
hook results and will not re-run the hook on its own.

Dev SDK: Flutter **3.47.5 (stable)**, Dart 3.13 — CI (`FLUTTER_VERSION` in
both workflows) is pinned to the same version. 3.47.5 ships a matched
engine/impellerc pair (both emit/expect bundle format v2), verified
end-to-end on-device. The one-time breakage on this machine was purely the
stale shadowing binary described above, not an SDK defect.
