# TryCatchDart — Project Context & Agent Handoff

> Ground station for model rockets ("Testing in Production"). Flutter desktop
> app (Windows x86_64 + ARM64, Linux, macOS — primary dev target Windows),
> "Precision Light" UI. This document is the single source of truth for all
> agents. **Keep it current. If you change something architectural, update the
> relevant section before you hand off.**

---

## Part 1 — Multi-Agent Coordination

> **Read this first. It prevents agents from stepping on each other.**

### 1.1 Ownership map

Each agent working in parallel must claim an area and stay inside it.
Cross-area changes require explicit coordination (see §1.4).

| Area | Canonical paths | Pinning tests |
|---|---|---|
| **Connectors** | `packages/serial/lib/connectors/`, `packages/serial/lib/telemetry/`, `packages/serial/lib/io/` | `connector_test`, `frame_codec_test`, `packet_parser_test`, `recorder_test`, `recording_header_test`, `file_parser_test` |
| **Dead reckoning** | `packages/dead_reckoning/`, `lib/core/dead_reckoning_adapter.dart`, `lib/ui/tiles/dead_reckoning_tile.dart` | package `dead_reckoning_test`, `dead_reckoning_tile_test`, `elevation_service_test` |
| **Core logic** | `lib/core/` | `ring_buffer_test`, `packet_rate_tracker_test`, `flight_events_test`, `highlights_test` |
| **State / providers** | `lib/state/` | `workspace_test`, `workspace_reorder_test`, `replay_seek_test`, `display_smoothing_test`, `replay_launch_site_test`, `launch_site_flow_test` |
| **Replay** | `lib/state/replay_controller.dart`, `lib/state/telemetry_store.dart` (replay paths) | `replay_seek_test`, `display_smoothing_test`, `mock_bq_test`, `flight_simulator_test` |
| **Map tile** | `lib/ui/tiles/map_tile.dart`, `lib/ui/tiles/shared/tile_io.dart`, `lib/ui/tiles/shared/offline_fallback_tiles.dart` | `map_track_test`, `map_tiles_test`, `map_follow_regression_test` |
| **3D / satellite tile** | `lib/ui/tiles/flight_3d_*.dart`, `lib/ui/tiles/onboard_camera_tile.dart`, `lib/ui/tiles/shared/flight_3d_*`, `lib/ui/tiles/shared/sat_*`, `lib/ui/tiles/shared/satellite_*.dart` | `flight_3d_scene_test`, `flight_3d_shell_test`, `onboard_vignette_test`, `rocket_mesh_test`, `rocket_centering_test`, `sat_render_test`, `satellite_ground_test` |
| **Charts / tiles** | `lib/ui/tiles/` (non-3D, non-map) | `chart_touch_test`, `time_series_decimation_test`, `scroll_zoom_test`, `dead_reckoning_tile_test`, `events_tile_test`, `trim_chart_test` |
| **UI chrome** | `lib/ui/screens/`, `lib/ui/components/` | `top_bar_theme_test`, `brand_mark_theme_test`, `brand_navigates_home_test`, `link_stats_button_test`, `serial_controls_overflow_test`, `channel_health_test`, `channel_health_edit_mode_test`, `grid_render_test`, `flight_trim_test` |
| **Theme** | `lib/theme/` | `top_bar_theme_test`, `brand_mark_theme_test` |
| **Linux native shell** | `linux/runner/`, `linux/CMakeLists.txt`, `packaging/linux/` | (manual) |

**Shared / dangerous files — coordinate before touching:**
- `pubspec.yaml` / `pubspec.lock` — dep changes affect everyone; agree first.
- `lib/state/telemetry_store.dart` — touched by Connectors, Core, State, and Replay agents.
- `packages/dead_reckoning/` — estimator/tune/eval/geo API; renames ripple into every tile + test that touches positions.
- `lib/ui/tiles/shared/flight_3d_scene.dart` — used by both 3D tile and rocket mesh work.
- `packages/serial/lib/connectors/registry.dart` — connector list; adding one re-resolves states/commands/events/capabilities across the UI. `packages/serial/lib/telemetry/frame_codec.dart` — MOCK wire format; any change invalidates mock recordings.
- `analysis_options.yaml` — changing lint rules can fail the whole tree for other agents.

### 1.2 Before you start a task

1. **Read this file.** Skim sections relevant to your area.
2. **Check git status.** `git status` — the working tree must be clean.
   If there are uncommitted changes from a previous agent, **do not stash them blindly**.
   Read what they are. If they are in your area, commit or discard them with justification.
   If they are in another area, stop and report — do not absorb foreign work.
3. **Run the baseline.**
   ```powershell
   flutter analyze
   flutter test
   ```
   Record the number of passing tests. If the baseline is already red, **stop and report** — do not start work on a broken tree. You are not responsible for failures you did not introduce.
4. **Claim your area** — note in your task description which ownership-map area you are in.
5. **Create a branch** (optional but strongly recommended for anything beyond a one-file fix):
   ```powershell
   git switch -c agent/<area>/<short-description>
   ```

### 1.3 While you work

- **Stay in your area.** If you discover a bug outside your area that blocks you, open a note in the session log (Part 8) and ask for a separate agent to fix it.
- **Do not use `git stash`** to hide work. Stashed changes are invisible to other agents and can be overwritten silently. Commit with a clear WIP message instead, or discard explicitly.
- **Commit small and often.** One logical change per commit. This makes rebasing and conflict resolution tractable.
- **Do not run the app.** The app requires hardware or a mock port and a desktop session. Ask the user for screenshots/descriptions instead. Run `flutter test` and `flutter analyze` to verify.
- **Do not modify tests that were green before you started**, unless the test itself is what you were asked to fix. If a previously-green test now fails, see §1.5.

### 1.4 Cross-area changes

If your task genuinely requires touching another agent's area:

1. **Stop.** Do not proceed unilaterally.
2. **Document** what you need changed and why (in the session log Part 8 or a comment).
3. **Coordinate** — either the other agent makes the change, or you explicitly take over that area for this task (acknowledge the full area's pinning tests).
4. **Run the full pinning test suite** for every area you touched before handing off.

### 1.5 If a test you didn't touch is failing

> This is the most common source of confusion in parallel work.

**Triage checklist — run in order, stop when you find the cause:**

1. **Was it failing before you started?** Re-check the baseline you recorded in §1.2 step 3. If yes, it is not your fault — report it and move on.
2. **Did you touch a shared file?** (see §1.1 shared/dangerous list). Even a formatting change in `telemetry_store.dart` can affect tests in multiple areas.
3. **Is the failure in a test that pins a contract your code must satisfy?** e.g., if you changed the wire format, `frame_codec_test` will fail — that is expected and you own the fix.
4. **Is the failure transient?** Some widget tests are timing-sensitive. Run `flutter test <test_file>` in isolation before blaming your change.
5. **Is the failure in a FS-backed screen test?** `path_provider` and `Directory.list` stall permanently inside the fake-async zone (widget tests). These tests cannot be written as widget tests — that is a known Flutter limitation, not a bug in your code.
6. If none of the above apply: **do not touch the failing test**. Write a clear note in Part 8, commit your work, and hand off.

### 1.6 Before you hand off / finish

1. **`flutter analyze`** must be clean (zero issues).
2. **`flutter test`** must be green. The count must be ≥ the baseline you recorded. If you added tests, the count should be higher.
3. **Update Part 8 (session log)** with a concise entry: what changed, which tests were added/changed, the new passing count.
4. **Update the relevant technical section** (Parts 2–7) if you changed anything architectural.
5. Commit everything with a clear message. No WIP commits in a finished handoff.
6. If you branched, do not merge — leave the branch and note it in Part 8. The user decides when to merge.

---

## Part 2 — Stack & Conventions

### 2.1 Toolchain

- Flutter SDK ^3.13, installed at `C:\Users\wwwho\flutter`. Desktop shells for Windows, Linux, macOS.
- Always run with `--release` for evaluation — debug builds are janky and misrepresent performance.
- `flutter analyze` + `flutter test` are the only CI gates. Both must be green before any handoff.
- Current passing test count: **506** (493 root `flutter test` + 13 `packages/dead_reckoning` `dart test` — update this when you finish).

### 2.2 Dependencies (key constraints)

| Package | Version | Gotchas |
|---|---|---|
| Riverpod | 3, no codegen | `Notifier`/`AsyncNotifier`. Use `AsyncValue.value`, **not** `valueOrNull`. `ProviderScope.overrides` injects the worker isolate in `main`. |
| fl_chart | 1.2 | `SideTitleWidget(meta: meta, child:)`, `LineChart(duration: Duration.zero)`, `StrokePattern.dashed`, `BarAreaData`. `BorderSide.strokeAlignInside` is a `double`, not an enum. |
| flutter_map | 8.3 | + `latlong2`, `vector_math` (`transformed(Vector4)`, `transformed3(Vector3)`, `scaleByDouble(x,y,z,w)`). |
| tray_manager | 0.7.0 | Linux: StatusNotifierItem over D-Bus (no appindicator needed). `linux/CMakeLists.txt` keeps `-Werror` for our code, suppresses `-Wno-deprecated-declarations` on `tray_manager_plugin` only, and maps `G_APPLICATION_DEFAULT_FLAGS`→`G_APPLICATION_FLAGS_NONE` when glib < 2.74 (ubuntu-22.04 ships 2.72; cnativeapi 0.3.0 needs 2.74+). Windows: `windows/CMakeLists.txt` silences MSVC C4267/C4996 on the `nativeapi`/`cnativeapi` targets only (our code stays `/W4 /WX`). |
| Others | — | `shared_preferences`, `path_provider`, `window_manager`, `flutter_libserialport`, local `packages/serial`. |

No router package (4 flat screens via enum provider). No `build_runner`/freezed.

### 2.3 Dark-mode const rule ⚠️

`AppColors` / `AppText.microLabel` / `AppText.monoValue` are **getters** that resolve the active palette at call time. **Never** hold them in a `const`, and **never** `const`-instantiate any widget that transitively reads them. `const AppShell` / `const TopBar` / `const`-screens froze whole subtrees across dark/light flips. Map tiles stay light in both modes.

### 2.4 Impeller / Windows-ARM64 blank-paint bug ⚠️

Per-card `BoxShadow` + `Clip.antiAlias` on grid tiles silently blanks the workspace grid — layout is correct, no exceptions thrown. Rules:
- `AppCard` has **no `boxShadow`** and uses `Clip.hardEdge`.
- Do not reintroduce either on grid tiles without testing on-device.
- Grid keeps dividers as invisible `Positioned` children in live mode so the Stack child count is identical in both edit and live modes.
- Nuclear fallback: `flutter::ImpellerSwitch::Disabled` in `windows/runner/flutter_window.cpp`.
- `Canvas.transform` with a perspective matrix paints fine (probed in `test/canvas_transform_probe_test.dart`; the engine plumbs `TransformFullPerspective` through). The satellite tile keeps its tessellated mesh anyway because DEM relief needs per-vertex heights, which 2D draw calls cannot carry — not because the transform is broken.
- The satellite drape's `drawVertices` input lists (positions/UVs/colors/indices) must be fresh objects per tier per frame — sharing/reusing the same list across tiers corrupts rendering (the engine must not see the same list with different content in one frame; symptom is a uniform brown smear). Scratch clip-space buffers that never escape into engine objects MAY be shared. Near-lens relief (clampEyeAboveTerrain margins, coarse tessellation) can still legitimately fill the frame with minified hillside — do not "fix" that with sky oracles; pin stability across micro camera moves instead (`hillside beside the lens` test).

### 2.5 Pointer input (desktop)

A precision-touchpad two-finger swipe arrives as `PointerPanZoom` events, **not** wheel scrolls. `flutter_map` ignores those for zoom; drag recognizers also ignore pure swipes. Every map/3D view must handle both paths:
- Wheel: `scrollWheelZoom` flag / `Listener.onPointerSignal`
- Trackpad swipe: explicit `onPointerPanZoomUpdate` handler

Map zooms with the wheel velocity, cursor-anchored via `focusedZoomCenter`, skipping updates that carry scale (flutter_map's pinch-zoom owns those). 3D shell + rocket tile zoom from swipe (`scrollZoomFactor`, ×1.1 per 120 units) and pinch, suppress drag-orbit while a trackpad gesture is active (a real press clears the flag). Pinned by `scroll_zoom_test.dart`.

### 2.6 Accessibility / AXTree

Global opt-out (user decision: the app doesn't need to be screen-reader
accessible). `MaterialApp.builder` in `lib/main.dart` wraps everything in a
root `ExcludeSemantics`, so the Windows embedder (semantics always on,
no reader running) gets an empty AXTree and the
`accessibility_bridge.cc(114) Failed to update ui::AXTree` spam stops at
the source. Visual `Tooltip` hover is unaffected. All former per-widget
`ExcludeSemantics` / `Semantics(container: true)` mitigations were deleted
as obsolete; do not reintroduce them. Leaf-consumer provider splits in
`playback_bar.dart` remain as pure rebuild-avoidance (perf), not AXTree
mitigations.

### 2.7 Theme

`lib/theme/`: white/dark cards (radius 12/8) on cool grey, hairline borders, monospace micro-labels (Consolas via `AppText`), team pink `#FF00A1` as the single accent (`pinkDeep` for text-safe accents; status stays green/amber/red). `AppCard` header = pink dot + mono uppercase label + hairline divider (**no tinted band**). `StatusPill` = mono uppercase stadium. Series colors: baro alt = pink, GPS/horiz = blue, dead reckoning/battery = violet, vert = green, accel = amber. Default system font (user declined bundling Inter).

### 2.8 Linux native shell

`linux/runner/my_application.cc`: `GtkHeaderBar` only on GNOME-like desktops (env `*DESKTOP*` has gnome/unity/pantheon/budgie, or X11 WM is GNOME Shell/Mutter); KDE Plasma and all other WMs fall back to a traditional title bar. Native title is `TryCatch`. X11 window icon resolves `linux/assets/icon.png` (dev) then `assets/icon.png` (bundle). On Wayland the icon comes from the hicolor theme via the `.desktop` entry (full 16–512 px set in `packaging/linux/icons/hicolor/*/apps/com.krychlic.trycatch.png`). `StartupWMClass=com.krychlic.trycatch` must equal the Wayland app_id. For `flutter run`, run `tool/install-linux-desktop-entry.sh` first.

---

## Part 3 — Connectors & Serial Package

`packages/serial/` — plug-n-play telemetry connectors. The shared internal
`TelemetryFrame` (SI units, `telemetry/telemetry_frame.dart`) is the only
thing that leaves the package: the worker parses the bytestream with the
selected connector and emits frames; the UI never sees raw bytes. Changing
a connector's framing invalidates that connector's recordings and must be
coordinated across Connectors, State, and Replay agents.

### 3.1 Connector interface

`connectors/connector.dart` (`TelemetryConnector`): stable `id` (stamped
into recordings) + `displayName`/`description` + `createParser()`
(bytestream → frames, owns framing/counters) + `states`/`stateForId`
(label, ARGB color, `hasNosecone`/`hasParachute`/`showsParachute`,
`pipeline` flag) + `commands`/`bytesForState`/`describeCommand` +
`events` (from/to state-id pairs) + `capabilities`
(`FieldCapabilities` over `TelemetryField` — which internal fields the
connector populates, so tiles render "not provided by this connector"
instead of waiting forever). `connectors/registry.dart`: `allConnectors`
(one class + one entry to add a connector), `connectorById`,
`defaultConnectorId == 'mock'`. Active connector persists as
`trycatch.connector_id`; the settings CONNECTOR card toggles it (locked
during replay), the worker follows via `ConnectCommand(connectorId)` /
`SetConnectorCommand`, `Recorder`/`StartRecordingCommand` stamp it.

### 3.2 MOCK connector (original format)

`connectors/mock_connector.dart` (`id == 'mock'`): sync `0xAA55` + payload
52 bytes (incl. trailing CRC16). `telemetry/frame_codec.dart`
`TelemetryLayout`, big-endian:

```
0  flags u8 (bit0 gpsFix, bit1 gpsFix3d)
1  seq u16              3  gpsLat i32 1e-7deg     7  gpsLon i32 1e-7deg
11 gpsAlt i32 cm        15 baroAlt i32 cm       19 velN i16 cm/s   21 velE   23 velD
25 accelX/Y/Z i16 mg    31 gyroX/Y/Z i16 centidps (±327 dps)
37 heading u16 centideg 39 roll i16 centideg 41 pitch 43 yaw
45 battery u16 mV       47 hall u16 raw (~2500 intact / ~2950 broken)
49 fsmState u8          50 crc16-ccitt (init 0xFFFF, poly 0x1021)
```

Units: WGS84 deg, metres, NED velocity (Down+), body-frame specific force
(+9.81 at rest), gyro deg/s, rocket-oriented attitude (pitch = tilt from
vertical, yaw = compass heading, roll = spin). CRC check vector
`"123456789"` → `0x29B1`. Populates the whole internal frame. FSM ids:
idle 0, armed 1, ascent 2, apogee 3, parachute 4, landed 5,
debug-unlocked 6, debug-locked 7, unknown 255 (pipeline = 0–5;
`hasNosecone` on idle/armed/ascent/debug-locked; canopy on parachute
only). Uplink `54 43 cmd arg` (arm/disarm/fire/beep/reset + `07`+id
set-state). Events: launch/armed→ascent, apogee, parachute, touchdown.
`FsmState` enum stays as the MOCK vocabulary + internal id fallback;
connector-driven surfaces use `stateForId` instead.

### 3.3 Recording file format

`io/recording_file.dart`: 168-byte v3 header + telemetry chunk stream +
command log. Header (big-endian): magic `TCR3` u32, payloadLength u16
(=52, mock), flags u16, start/end micros i64, packetCount u64, max
baro/speed/accel f32, launch lat/lon i32 1e-7deg, launch MSL f32, launch
name 48 B UTF-8 NUL-padded, CRC16 over bytes 0..103, reserved, then a
section directory (headerLength=168, version=3, telemetryByteLen u64,
commandsOffset u64, commandCount u32, directory CRC over 108..131 +
134..167, reserved) + connector id 32 B UTF-8 NUL-padded. The chunk stream
is the recording connector's raw bytestream — playback resolves the
connector from the stamp and auto-selects it (in-memory override,
restored on stop). Command log: fixed 16-byte records (i64 tsUs + 4 raw
uplink bytes + status + source). v1 `TCRC` and v2 `TCR2` files are
rejected — convert v2 with `dart run tool/migrate_recordings_v3.dart`
(stamps `mock`, keeps `.v2.bak`).

**Launch site is mandatory.** `start()` requires a site + connector id
(provisional header already carries both, so even crash-interrupted files
are valid). `stop()` finalizes via `finalizeRecordingFile` (never throws;
idempotent). No first-GPS-fix fallback — siteless files are rejected
everywhere. Magic-less files are rejected. Chunks carry a 12-byte header
(i64 µs + u32 len).

> ⚠️ `crc_real_flight.bin` on disk is stale (pre-dates de-versioning). Re-convert from `flight_data.js` before use.

### 3.4 Mock simulator

`FlightSimulator` (seeded): coldStart 2 s → pad 6 s (armed after 2 s) →
boost 2.8 s @55 m/s² → coast (drag 4e-4) → apogee ~1058 m + hall break →
drogue (~40 m/s) → main @150 m (~6 m/s) → landed (pitch 85°). GPS
random-walk, eastward wind drift, battery 8.4 V −2.5 mV/s. Prague pad.

`MockSerialPort` (`MOCK`): 10 Hz + 20 s interference cycle (12 s clean /
4 s light / 4 s heavy + bit-flipped clones) — sweeps all channel-health
verdicts.

`MockBqSerialPort` (`MOCK-BQ`): same flight + interference, drops link
completely for ~5 s every ~15 s — exercises dead reckoning gap filling
and stale-link UI.

`MockDcSerialPort` (`MOCK-DC`): chaos mock for the failure UX — randomly
refuses opens (~30%), drops the link dead mid-stream (~25 s mean, stays
down until reconnect), and NAKs uplinks (~10%) while staying up
(half-open TX stall). Rates are constructor-tunable (0.0/1.0 = deterministic
for tests). Exercises the connecting pill, error/disconnect/command-failed
toasts, and the watchdog path with no hardware.

Worker isolate: typed commands
(Connect[+connectorId]/SetConnector/Disconnect/ListPorts/StartRecording[+connectorId]/StopRecording/SendBytes)
and events (Packet[frame]/PortList/Status[+connectorId]/Error) over
`SendPort`. `TelemetryStore.ingest/ingestFrames` take frames directly;
`ReplayController` ticks/seeks frames; `detectFlightEvents` takes the
connector's event table; `buildChannelProfile` takes the connector.

---

## Part 4 — App Architecture

```
lib/
  main.dart          worker spawn → ProviderScope override → AppShell
  ui/screens/        AppShell, router, TopBar, dashboard (tabs + grid),
                     recordings (+orbit previews), settings
  ui/components/     BrandMark, SerialControls, LinkStatsButton,
                     RecordingControls, PlaybackBar,
                     AppCard, StatusPill, ToolFab, WaitingForData,
                     CenteredValue, CopyButton, FlightEventDot,
                     FlightEventStyle
    ui/tiles/        18 telemetry tiles (incl. channel health and events);
                     shared/ = TimeSeriesChart, ChartValueHeader,
                     Flight3dShell, flight scene/painters/shell,
                     rocket mesh, orbit camera, map/satellite tile I/O
  state/             telemetry_store (ingestion point),
                     telemetry_provider (streams + serial config),
                     connector_provider (active connector id + resolve),
                     replay_controller, layout_tree,
                     workspace_models, workspace_controller,
                     launch_site_store, router, orbit camera,
                     theme_mode_provider
  ui/tile_registry.dart  tile descriptors (UI composition, was state/)
  services/          flight_trim, prefs_keys, recording_repository,
                     elevation_service (was state/)
   core/              pure logic (no Flutter/Riverpod):
                      dead_reckoning_adapter, ring_buffer, channel_health,
                      packet_rate_tracker, format, flight_events,
                      flight_stats, elevation_math, path_utils
   theme/             app_colors (palette + AppThemeMode + tokens), app_theme
packages/serial/     connectors/ (interface + registry + mock),
                     framing, codec, worker isolate, mock simulator
packages/dead_reckoning/  project + position + sample + geo
                     (pure Dart; app maps frames via dead_reckoning_adapter)
```

### 4.1 TelemetryStore

Ingest pre-decoded connector frames, dead reckoning projection (`packages/dead_reckoning`), ring buffers (9000 ≈ 15 min @10 Hz), auto-reset on port change + connector change, skips live ingestion while replaying, 80 ms throttle. `history`/`deadReckoningHistory` are zero-copy live views. Dead reckoning is a live-only gap filler: a stateless function of the last packet + elapsed time (last position + velocity·dt + ½·acceleration·dt², acceleration from the longitudinal accel channel rotated onto the nose plus gravity; flat ground plane at 0 with touchdown freeze). Points enter history while GPS is silent ≥1 s; a 100 ms timer projects through total link loss (live only). `deadReckoningStaleMs` (1000) is the shared stale threshold.

Persisted keys (`services/prefs_keys.dart`, no version suffixes): `trycatch.workspaces`, `trycatch.launch_sites`, `trycatch.dark_mode`, `trycatch.connector_id`.

### 4.2 Known weak points (out of scope — do not fix without a dedicated task)

- `AppThemeMode` singleton lives outside Riverpod.
- `ref.listen` in `build` (channel tile/pill, packet-rate tracker).
- `ref.read(workspaceProvider).value` staleness in some places.
- `TelemetryStore` is a god-store with bidirectional `ReplayController` coupling (sync `seek()` janks large files).
- Global orbit camera shared across 3D tiles.
- `SerialConfigNotifier` mixes UI/IO/FS concerns.

---

## Part 5 — Workspace Layout (KD-tree)

`SplitNode{id (stable), vertical, ratio, a, b}` | `LeafNode{tileId, tileType}`. Every tile type has a pixel min size; `layoutTree()` clamps splits to minimums.

Pure ops: `insertLeaf` (splits largest leaf, orientation from last-known shape), `removeLeaf`, `swapLeaves`, `treeFromOrder` (factory default), `SplitNode.flipOrientation` (double-click a divider in edit mode).

JSON: `{type:'split',id,vertical,ratio,a,b}` / `{type:'leaf',tileId,tileType}`.

Controller: addTile/removeTile/swapTiles/setRatio/setActive/create/duplicate/rename/delete/resetToDefaults/persistActive. Drags mutate with `persist:false`, persist on release. Grid memoizes layout by root identity + size.

Edit mode: dividers draggable, drag-to-swap, per-tile split/remove, tile content in `AbsorbPointer`. Dashboard: tabs (Ctrl+1..9, right-click menu, tooltips), Edit layout toggle, Add-tile picker, Reset with confirm.

Tile registry is data-driven — new tile = one class + one descriptor entry (id, title, description, minSize, immersive, builder).

---

## Part 6 — Tiles Reference

### 6.1 Shared pieces

- **`TimeSeriesChart`**: raw data, no smoothing. 60 s rolling window live; replay shows whole flight (played full opacity + remainder 25%). 1-2-5 y steps with zero baseline. Flat data opens the axis (was the `horizontalInterval = 0` crash). Decimation ≤400 pts by absolute packet time. Legend collapses under ~120 px tile height.
- **`ChartValueHeader`**: big readout for battery/hall.
- **`CenteredValue`**: centred headline + sublabel. Pins a tight `LayoutBuilder` box so `FittedBox` actually shrinks.
- **`Flight3dShell`**: camera-state mixin + gesture canvas / tool column / readout.
- **`tile_io.dart`**: Esri URLs, download, image check, shared disk cache.

### 6.2 Charts

Thin wrappers over `TimeSeriesChart`: altitude, velocity (horiz/vert-dashed/total), acceleration (vert-dashed/total), battery (+discharge rate line, hidden when short), hall (no legend, threshold 2700 colors the readout).

### 6.3 Non-chart info tiles

- **FSM**: big state + time-in-state (1 s ticker; replay uses playhead). Progress bar + pipeline/off-pipeline chip grids from the active connector's states. Two-click send mirrors the control panel. `NotProvidedByConnector` when the connector has no FSM.
- **Max alt**: peak + NOW.
- **Nose cone** (`nosecone`): padlock icon + LOCKED (green) / UNLOCKED (red) from `hasNosecone`.
- **GPS position** (`stats`): large coordinates, one `·`-joined line (altitude + drift), fix-status footer, copy + QR-code actions.
- **Dead reckoning** (`dead_reckoning`, live only): link-healthy placeholder while packets flow; shows extrapolated coordinates on packet loss. Disabled during replay. Both share `PositionReadout`.
- **Highlights** (`highlights`): session extremes — max ascent/descent velocity, top speed (Mach), max acceleration (G). Replay-only third row: total drift + max altitude. Pinned by `highlights_test.dart`.
- **Events** (`events`): newest-first log. Live rows read "Launch — 12 s ago" (1 s ticker). Replay rows read "Launch — at 1:23" and tap to seek; future events dimmed.
- **Control panel**: active connector's command catalog (MOCK = `RocketCommands` — bytes are **MADE-UP and must be aligned with real firmware before flight**). Two-click confirm (3 s). Disabled while disconnected or replaying. "No commands on this connector" when the catalog is empty.

### 6.4 Map tile

Immersive. Esri street / satellite (overzoom past 18). 1 GB disk cache. Precache zooms 13–17 ~1 km around saved sites. GPS solid blue vs per-gap dashed violet dead reckoning. Follow/satellite/zoom ToolFabs. `TileDisplay.instantaneous()` on both tile layers. Per-layer background colors (`satelliteMapBackground` near-black, `streetMapBackground` pale paper). Cropped fallback tiles memoized in 128-entry LRU `CroppedTileCache`.

### 6.5 3D tiles

All immersive. Metric scene east/up/south metres, origin = site or first fix. GPS trail only, dead reckoning as single violet point. Drop line, 1-2-5 ground grid with N/E labels. N/E/U compass. Three tiles: **Flight path** (plain ground), **3D Flight** (satellite ground), and **Onboard camera** (fixed strap-down lens over satellite ground). Orbit modes chase/orbit-field/free (80° cap), wheel zoom, double-tap reset. Onboard rides at the airframe looking out its side, nose up; drag spins the gaze around the long axis, double-tap recenters, no zoom or mode picker. World frame X east / Y up / Z south (right-handed; locked by `flight_3d_scene_test.dart`).

Satellite ground (`SatFlightPainter` + `SatelliteTerrainState`, shared by 3D Flight and Onboard camera) drapes Esri imagery as a screen-space mesh (one node per ~21 px ray-cast; parent-tile fallback; ≥5 km²; failures uncached + 15 s backoff) with procedural sky. **Never** `Canvas.transform` perspective drape — silently paints nothing on Impeller/OpenGLES.

**Performance** (`_paintMeshTier`): indexed drawing (up to 5× fewer vertex submissions), sub-pixel pad tier culling, quad-level frustum culling, static `Float32List` scratch buffers, inlined color caching, lazy `meshUvs`. 60-frame benchmark: 3,489 ms → 1,219 ms (median 57.7 → 20.2 ms).

**Perspective distortion**: adaptive 4D clip-space sub-tessellation in `emitTri` when `w_max > w_min * 1.5`. Mean error: 3.012 → 1.308.

**Depth ordering**: view-dependent far-to-near traversal (`terrainTierDrawOrder`). Pinned by `satellite_ground_test.dart` + `sat_render_test.dart`.

### 6.6 Top bar

Fixed-width skeleton (nothing shifts in any state). Slots: brand · link group (port dropdown incl. Rescan + Connect, link-stats button) · hairline · launch-site button · session (Record) · menu.

Link-stats button: left half = live pkt/s decaying to "N s ago" past 2 s liveness window; right half = unknown B/s. Color = max(packet severity, congestion severity). No packets within 2 s → red. Neutral only before any data ever arrived.

Launch-site button (flag + site name, amber SET SITE when unset): preset list (tap selects), manual entry, save-current-rocket-position. A site is always selected — no Clear; deleting active preset falls through. Record stays disabled until a site is set. Reset is in the menu (confirm dialog, disabled without data or during replay).

Replay: REPLAY badge + filename + play + time + flexible slider + speed popup + Back to live.

### 6.7 Channel health

Verdicts on unknown B/s: clear <50, activity <400, else interference. Dashboard tile = compact verdict row + rolling/replay chart (the only channel-health surface — the old Monitor screen is deleted, `ChannelHealthMonitor` with it; the tile keeps `ChannelHealthTile` + shared `_RateChart`/`_ReplayChart`). Top-bar button always shows pkt/s + unknown B/s regardless of connection state and opens the Dashboard.

### 6.8 Dead reckoning tuning screen

Minimal overview home state: a centered Dead reckoning headline, one tune line whose button morphs copy → apply when pasted over (truncating, single line), Generate new tune, and a Manual tune door into a number-grid dialog (Sensor fit / Motion / Limits, inline validation, Reset inside). No factory/tuned distinction, no paragraphs, no cards. The wizard is a left rail (Flight → Results) with live node states — numbered ring for current, filled check for done — plus one-line statuses, connected by hairlines; tapping an unlocked node jumps to it; the page scroll resets to top on every step change. The right pane shows one step inside a card: Flight (picker + Find best tune + progress + Close), Results (current → new rows for average miss and vertical error, legend + 3D preview carousel with settle ring, Apply/Discard with no Back — Discard exits to the overview). The rail stays vertically centered while the step content scrolls. Synthetic outages are fully automatic (period = duration/6 clamped 15–60 s, 5/15/45 s short/medium/long tiers cycling over the grid with fallback to shorter tiers, per-phase top-up at 15 s, one 45 s window in the longest scorable phase when the flight fits it, cap 12; unknown phases kept when no frames exist). Tuning scores the duration-weighted rotation-invariant mean (15 s weighs 1, 5 s weighs 3, 45 s weighs 1/3), so longs cannot outvote shorts. Preview labels carry the window length (`+1:23 · Parachute · 45s`) and previews run with the same terrain as tuning. Grounded phases are out of the scoring world entirely: only Ascent/Apogee/Parachute masks score. Preview language: flown input solid blue, new guess solid purple, actual continuation solid pink, no ground drop lines, 10 s lead-in, cutout dot at the cutout. Transition-spanning outages are previewed but excluded from the tuning objective; on `crc26_cleanedup_trim.bin` the automatic masks score ~1 m mean on the within-phase windows. No status pills, giant scores, icon-buttons, compass, sliders, mode toggles or dropdown paging. The estimator integrates velocity trapezoidally (exact for ramps; old backward Euler overshot every accel phase) and optionally follows a least-squares acceleration trend (800 ms window, ±25 m/s² clamp, 4 s trust budget, horizontal only, off when drag is set; default on). Vertical is regime-aware: fix-to-fix GPS altitude rates teach online climb/descent scales (the reference flight's variometer reads 1.2× on ascent but 0.3× under canopy), unsteady spans (opening shock, ringing) are rejected from learning via a spread guard, and descending with a learned rate holds toward the terminal rate instead of gravity-plunging (measured −80 m → ±5 m on 10 s parachute outages of `crc26_cleanedup_trim.bin`); ascent without canopy evidence keeps the exact-kinematics gravity arc, so a predicted apogee crossing settles onto the learned rate — mid-outage state changes are predicted from pre-outage data only, never leaked from in-outage truth. Every `DeadReckoningPosition` carries a `regime` label (`climb`/`descent`/`level`/`landed`) for previews. Live estimator follows terrain shape: `TelemetryStore` keeps tile→elevation for visited tiles (`elevationTileCenter`) and pushes them via `setTerrainSamples`; the package looks the floor up at the predicted position (nearest sample < 15 km, `max()` merge). `flutter analyze` clean, **348 green root + 50 green package = 398 total**.

### 6.9 Replay timeline events

`FlightEventType` is the nominal style vocabulary (launch/apogee/parachute/touchdown); detection in `core/flight_events.dart` runs the active connector's event table (`TelemetryConnector.events`) and `FlightEvent` carries its own label/transitionLabel with a nullable style type (fallback flag style for connector-specific transitions). Icon + palette color in `ui/components/flight_event_style.dart` + shared `FlightEventDot`. Dots dim until playhead reaches them; tapping seeks. Markers that would overlap spread into lanes (`placeFlightEvents`, greedy, 16 px targets). Slider theme pinned (4 px track, r10 thumb, r24 overlay — M3 defaults), fixing thumb travel to 24..width-24.

---

## Part 7 — Replay & Recordings

### 7.1 Replay

`replayProvider.play(path)`: parses with the header-stamped connector (valid v3 header + known connector + site required), auto-selects that connector for the session (restored on stop), stores header site. Whole flight pre-decoded once for fixed chart axes. 50 ms ticker × speed (MAX = dump). `seek()` is binary search + forward-delta bulk ingest (`TelemetryStore.ingestFrames`, one state rebuild). Auto-pauses at end unless `loopEnabled` (repeat toggle in the playback bar) wraps to the start carrying the overshoot. Space toggles pause/play via an `AppShell`-level `CallbackShortcuts` binding (focused buttons/switches win via `ActivateIntent`; text input guarded). No dead reckoning during replay.

Display smoothing (replay-only, toggle in playback bar, default on): 3D trail uses centered ±25-packet moving average; attitude from averaged specific-force vector. File, charts, map stay raw. `buildReplayScene` over full pre-decoded frames (smooth-then-decimate with ±25 lookahead). Pinned by `display_smoothing_test.dart` + `replay_seek_test.dart`.

### 7.2 Recordings screen

Stat-first scan (fixed v3 header: site/stats/connector) + per-card concurrent preview decode with the file's own connector (session cache by path+size+mtime). Video-style cards: whole 200 px preview is the tap target, pink center play button, primary border while loaded, header `…` menu for trim/extract-site/delete, extent 284. `TrimChart` renders `FlightEventDot`s on the altitude curve (x from flight-clock fraction, y from nearest decimated profile value, downward de-collision, dimming for cut markers).

### 7.3 Factory workspaces

- **Flight**: default live view — highlights, FSM, charts, map, 3D, channel health.
- **Prep**: pre-flight check — channel health prominent.
- **Recovery**: live dead reckoning tile.
- **Replay**: no control panel / dead reckoning.

---

## Part 8 — Session Log

> **Agents: append a new entry here for every significant session. Keep it terse but complete: what changed, which files, which tests added/changed, new passing count.**

---

### 2026-09 (initial sessions)

- Structure refactor: de-versioned wire (52 B) + header (108 B). Dropped legacy decoders, migrations, converter. Extracted shared UI. `widget→tile` rename.
- UI/UX pass: dropped pressure; fixed dark-mode leaks; immersive map/3D; responsive shedding.
- Overflow pass: bounded `CenteredValue`; dropped battery/hall pills; topbar regrouped + REPLAY badge.
- Topbar rethink: rescan folded into port dropdown, Reset moved to menu, fixed-width skeleton, replay slider single Expanded. Channel screen rewritten in plain language.
- AXTree spam fix: `ExcludeSemantics` on display-only live readouts; `Semantics(container:true)` per bare tooltip anchor (flutter/flutter#182444). Replay filename badge hoisted behind path-only watch.
- Launch-site flow redo (saved-only): store normalizes on load, "Use without saving" removed. Fixed settings dropdown assertion crash. Port-switcher overflow fixed.
- Channel screen: TOTAL series dropped; FSM debug states always render (arithmetic fit check). BrandMark uses `assets/icon.png`; de-consted TopBar wrappers.
- Sites dialog redo: saved list, Add on top. Sites removed from settings. `tileCacheCoverage` probes exact precache URL set.
- Mandatory launch site: `select()` non-nullable; `LaunchSiteButton` in topbar; Record disabled without site.
- Linux tray fix: per-call guards; `setTitle` on Linux; `popUpContextMenu` skipped; icon resolves to absolute path.
- Real flight converted: `Documents/TryCatch/recordings/flightlog_tcrc.bin` (26,214 packets, ~17.5 min, LKMK 2026-07-10, Prague pad, MSL 403 m).
- Replay display smoothing + seek performance: binary search + bulk ingest `seek()`; 50 ms ticker batches. **182 green.**
- Replay 3D follow-up: shared smoothing for rocket + trail (`buildReplayScene`); launch-pad camera; play/pause via `ReplayController.toggle()`. **182 green.**
- 2D map performance: skeleton no longer subscribes to telemetry; leaf consumers on narrow version selector; `ref.listen` for follow; stride-decimation ≤1500 GPS pts; O(history+dr) DR segments; `TileDisplay.instantaneous()`. **247 green.**
- 2D map white-flash + crop cache: per-layer background colors; 128-entry LRU `CroppedTileCache`. **262 green.**
- Replay timeline event markers: clickable milestone dots, pure `core/flight_events.dart`, `replayFlightEventsProvider`, `placeFlightEvents` lane algorithm, slider theme pinned.
- `FlightEventType` data-driven; `events` tile: newest-first log, live ages, replay tap-to-seek.
- Recorded-flight card redesign + trim event markers: video-style cards; `TrimChart` with `FlightEventDot`s.
- Satellite 3D depth + perspective + performance fixes: far-to-near traversal, clip-space sub-tessellation, indexed drawing, culling, static scratch buffers. **262 green.**
- Replay loop + Space transport: `ReplayState.loopEnabled` + `setLooping()` (survives reload, resets on stop), end-of-flight wraps via `_restartLoop` with overshoot carry; repeat toggle in playback bar; Space pause/play in `AppShell` (`CallbackShortcuts`, text-input guarded, inner `ActivateIntent` wins); transport tooltips advertise Space. Tests: loop persistence/reset (`replay_seek_test`), loop button + Space tooltip (`flight_events_test`). **347 green.**
- Toolchain upgrade: Flutter 3.47.2 → 3.47.4 (Dart 3.13.2 → 3.13.3). `flutter pub upgrade`: archive 4.2.0→4.3.0, code_assets 2.0.0→2.1.0, image 4.9.2→4.10.1 (all transitive; every direct dep already at latest resolvable). CI `FLUTTER_VERSION` pins (`ci.yml`, `release.yml`) bumped to 3.47.4. `flutter analyze` clean, **347 green.**
- 3D renderer cleanup + optimization (no engine switch — see Part 9): shared `resolveFlightScene`/`resolveDisplayAttitude` in `flight_scene_builder.dart` (dedupes live-vs-replay + attitude logic across all 3 tiles); trail + ground grid batched to ~3 draw calls via shared `clipWorldSegment`/`appendWorldSegment`; rocket mesh single fill pass (dropped the same-color 0.6 px stroke overdraw, reused Paint/Path); satellite drape: hillshade quantized to 1/128 (color-cache hits), generic sub-pixel tier cull for mid + pad (`_tierQuadPixels`, `_subPixelCullPx`), DEM-null fast path reuses the scene (no per-frame resampling), mesh sync extracted to `_syncMeshes`. Pixels unchanged (render-test stability metrics identical). `flutter analyze` clean, **347 green.**
- Trail wobble fix: `capTrailPoints` was tip-anchored and re-phased the whole trail past the 400 cap — measured 99.4% of displayed points jumping every growth step. Rewrote start-anchored with power-of-two stride (appends only append/thin, surviving points never move; proven zero teleports outside the fresh tail). New regression test `growing flights never move displayed points (no crawl)`. The mid-tier sub-pixel cull added in the previous pass was reverted (anchor-distance approximation is weakest exactly where it would trigger; mid is only ~9k verts) — pad cull unchanged. `flutter analyze` clean, **348 green.**
- Ground revert (user report: ground looked worse): restored the original ground rendering everywhere — plain-tile grid back to per-line `drawWorldSegment`, satellite drape back to exact (unquantized) hillshade, original inline pad-tier cull, original per-frame DEM clamp path (removed the DEM-null fast path). Then, per explicit follow-up, removed every remaining ground-tile change: `flight_3d_satellite_tile.dart` is back to zero diff (original scene block + inline mesh sync, `_syncMeshes` deleted). Kept, per user confirmation that the trail is good: the `capTrailPoints` growth-stability fix + its regression test, the batched trail path, the single-pass rocket mesh, and the behavior-identical `resolveFlightScene`/`resolveDisplayAttitude` refactors in the non-satellite tiles. `flutter analyze` clean, **348 green.**
- Dead reckoning extraction (`agent/core/dead-reckoning-package`): new pure-Dart `packages/dead_reckoning/` owning estimator + `DeadReckoningPosition`/`DeadReckoningSample`/`DeadReckoningTune` + gap scoring (`detectDeadReckoningGaps`, `syntheticDeadReckoningGaps`, `evaluateDeadReckoning`) + `geo` (moved from `lib/core/`). No "DR" abbreviation anywhere: `DrPosition`→`DeadReckoningPosition`, `drSegments`→`deadReckoningSegments`, `drStaleMs`→`deadReckoningStaleMs`, `rocketIsDr`→`rocketIsDeadReckoning`, `paintDropLineAndDr`→`paintDropLineAndDeadReckoning`. App maps frames via `lib/core/dead_reckoning_adapter.dart`; store applies tunes via `setDeadReckoningTune()` (in-memory; lab UI + persistence are a follow-up). Behavior-preserving by default (tune defaults = historical constants) plus one hardening: estimator clock never rewinds on out-of-order samples. Tests: root `dead_reckoning_test.dart` (17) replaced by package `dead_reckoning_test.dart` (27: ported estimator/geo + tune JSON/compact + drag/clamp/horizon + eval). `flutter analyze` clean, **331 green root + 27 green package = 358 total**.
- Rotation-invariant tuning (same branch): every real recording carries wind from one arbitrary direction, which must not leak into the tune. `rotatedDeadReckoningSamples()` rotates positions + horizontal velocities about the first fix (time/altitude/fix flags untouched, so time-based masks apply unchanged); `evaluateDeadReckoningRotationInvariant()` replays 8 evenly spaced headings (default, every 45°) and reports the mean of per-heading means plus worst-heading mean and heading spread. Headline tuning objective is the cross-heading mean. 5 new package tests (identity/quarter/full turn, steady leg near-zero on all headings, single-heading == plain eval). `flutter analyze` clean, **331 green root + 32 green package = 363 total**.
- Tuning lab UI (same branch): `MonitorScreen` is now two tabs (Channel health | Dead reckoning); router label `Channel health`→`Monitor`. New `DeadReckoningLabTab` (recording picker, real/synthetic outage config, 1/4/8 headings, draft-tune sliders incl. nullable clamps/horizon, defaults-vs-draft results, `DEADRECKONING1.*` copy/paste share card) + `deadReckoningTuneProvider` (persisted `trycatch.dead_reckoning_tune`, applied live via `TelemetryStore.setDeadReckoningTune()`). Measured on the real recordings before building: `crc26.bin` (4,088 frames) and `crc26_full.bin` (26,214 frames) both carry **zero real GPS gaps**, so the lab falls back to synthetic outages with a note; 8-heading eval costs 29 ms / 126 ms (synchronous, no isolate). Synthetic masks now skip the t=0 window (never scorable). Tests: `dead_reckoning_tune_store_test` (6: defaults, persist+apply, reload, corrupt, parse, reset) + `dead_reckoning_lab_tab_test` (4 widget tests via injected samples). `flutter analyze` clean, **341 green root + 32 green package = 373 total**.
- Lab promoted to its own screen (same branch, user feedback: tab was hard to find, flow unclear): new `AppScreen.deadReckoning` (`Dead reckoning`, hamburger menu, `IndexedStack` slot); `MonitorScreen` back to channel health only. Lab reworked into 5 numbered steps with plain-language helpers, a full-width Score button, and two paired-bar charts (miss by heading over 8 compass points, miss by outage oldest-first) plus a win/lose/tie verdict. Fixed an empty-debug-samples crash (`.first` on `[]`). `flutter analyze` clean, **341 green root + 32 green package = 373 total**.
- Lab simplified again (same branch, still too wide/unclear): narrow centred 640 column in the Settings voice; flight+outages merged into one card; limits behind a switch; results lead with a verdict `StatusPill` + big `CenteredValue` draft mean miss, then dot-status rows and compact charts (8-column vertical heading strip with value tooltips, paired outage bars capped at 8). `flutter analyze` clean, **341 green root + 32 green package = 373 total**.
- Optimize-first rework (same branch): the lab is now flight → optimize → performance → share. Package gains `optimize.dart`: coordinate descent over drag/smoothing/tolerance/clamps/horizon (never gravity — fixed physics), ties keep the incumbent, single upfront rotation reused across candidates, yields between candidates for progress + cancel. Plus `predictDeadReckoningTrack()` (per-sample predictions inside masks) feeding a top-down `DeadReckoningTrackPreview` (blue truth, pink guesses, no tiles). Gravity slider removed from the UI (static fixed row). Tune card is now optional fine-tuning; Optimize adopts the winner and auto-scores. Tests: optimizer beats defaults on a braking leg / holds defaults on a steady leg / progress+cancel / prediction-track geometry; widget test optimizes end-to-end. `flutter analyze` clean, **342 green root + 36 green package = 378 total**.
- Why the optimizer never won (same branch, measured on `crc26_cleanedup_full.bin`): the old recording had horizontal velocity pinned at 0.0 in all 26k frames — zero signal, no dial can fix that. On the fixed file, velocity bearing matches the GPS track within 0.1° but speed reads 20–35% low: per-rocket IMU scale error. New `DeadReckoningTune.velocityScale` (default 1.0, horizontal only, swept first at 0.8–1.4) + estimator applies it to adoption and live integration. Optimizer now finds scale 1.1 + tolerance 5.0: **3.56 m → 3.35 m** mean miss. Page shortened too: tune sliders deleted, individual params live in a Manual tune dialog (number grid with explanations + validation); Optimize card has reload-active + Manual tune buttons. `flutter analyze` clean, **347 green root + 37 green package = 384 total**.
- Guided re-tune dialog + terrain-shaped clamp (same branch): landing page is now just current tune + share string + Re-tune/Manual-tune doors. `RetuneDialog` runs flight → results: step 1 picks a recording + outage shape and searches (terrain tiles along the track queried best-effort into every estimator); step 2 shows current vs new as two big 0–100 match scores, per-phase rows (Ascent/Apogee/Parachute/Landed/Pad from frame FSM), and a drag-to-rotate 3D outage preview (pre-cutout solid blue, estimate solid pink, real dashed blue, outage window only) with stepper — then Apply/Cancel. Package: `terrain.dart` + spatial floor lookup (< 15 km, `max()` merge, threaded through eval/optimize/predict); `scoreDeadReckoningByScenario`; `deadReckoningMatchScore`. Live store feeds visited-tile elevations as spatial samples. `flutter analyze` clean, **346 green root + 41 green package = 387 total**.
- Re-tune honesty + preview polish (same branch, from screenshot review): the win pill compared raw floats while showing rounded integers (60 vs 60 reading NEW TUNE WINS) — it now compares the displayed integers, and an unchanged tune reports Already optimal instead. Step 2 reordered (scores → preview → phases) with tighter spacing and one merged caption line. The 3D preview gained a ground grid plus an N/E/up compass overlay that follows rotation. Verified the trim file still optimizes (10.9 → 9.7 m via scale 1.1 — a real but sub-integer win, now honestly a Tie). `flutter analyze` clean, **346 green root + 41 green package = 387 total**.
- Vertical regime rework + lab de-badging (user: prediction not good, UI unintuitive/AI-ish): benchmarked `crc26_cleanedup_trim.bin` (4,138 frames, 100% fixes, mostly parachute) and found the vertical channel 3× off — reported `velocityDown` ≈ 11.5 m/s vs GPS+baro altitude rate ≈ 3.8 m/s (horizontal matched, so not a global scale). Root causes: gravity arc applied to terminal descent (plunged −80 m per 10 s outage, then froze on the ground clamp) and no vertical calibration knob. Fix is estimator-only, no tune format change: fix-to-fix GPS altitude rates teach online climb/descent scales (ascent 1.2×, canopy 0.3× on the reference flight); descending with a learned rate holds toward the terminal rate, ascent without canopy evidence keeps the gravity arc, so predicted apogee crossings settle onto the learned rate (mid-outage state changes predicted from pre-outage data only). Positions carry a `regime` label for previews. Measured: 10 s masks 10.9 → 3.2 m mean (score 69.6 → 88.5), 30 s masks 71.3 → 3.6 m (26.0 → 87.5), vertical RMSE 63.5 → 3.3 m. Lab keeps its flow but drops all pills/giant scores/icon-buttons: verdict sentence, plain current → new rows (average miss + vertical error), outage dropdown, transition-span notes, descent-settle ring in the 3D preview, Manual dialog grouped Sensor fit / Motion / Limits. Tests: 4 new package tests (terminal hold, variometer calibration, apogee settle, regime labels); lab widget tests updated to new wording. `flutter analyze` clean, **347 green root + 49 green package = 396 total** (root −1 vs §2.1's 348 is the earlier `eee075e` benchmark-file removal, pre-existing).
- Lab rewrite from scratch (user: drop the compass, cover ascent/apogee, redo the confusing UI): corner E/U/N compass deleted from the outage preview; synthetic outages topped up per flown phase so `crc26_cleanedup_trim.bin` scores Ascent, Apogee, Parachute ×2, Landed with defaults; transition-spanning outages previewed but excluded from the tuning objective (unwinnable by construction — tuning on them games the freeze); the page is now three AppCards with no dialogs (Flight → Results → Tune, Settings-card grammar: what-this-is line, content, status line, one primary action), manual numbers inline with an applied-confirmation state. Estimator: unsteady-span guard rejects opening shock/ringing from vertical learning (pinned by test). Transition masks stay visibly hard (apogee→chute ~100 m — sensor garbage + unknown chute timing, shown labeled, not hidden). Widget tests rewritten (5: page shape, search+apply, discard, manual reject/save) with a two-direction page-scroll helper (every TextField hosts an inner scrollable; ListView lazily unbuilds). `flutter analyze` clean, **348 green root + 50 green package = 398 total**.
- Iteration fixes (user: too long, two previews, numbers on home, weird buttons): removed a duplicated `_OutagePreview3d` (the carousel edit had left the old view below the caption — also half the review height); manual numbers moved from the overview into a `_ManualTuneDialog` (same sections/validation/keys), overview keeps doors only; Flight Back → Close (it exits the wizard), applied Dismiss → Clear; frameless flights keep all masks (landed filter only applies with frame phases); carousel items shortened with the outage label on its own line. Tests (8 lab) updated to dialog flows. `flutter analyze` clean, **350 green root + 50 green package = 400 total**.
- Slim wizard + preview language + monitor deletion (user: no outages screen; fix tall/weird review; share dialog; settings cards; drop monitor screen): Outages step merged into Flight (select → confirm/run → review; 2-node rail), all outage configuration deleted with it (stale machinery went too — nothing left to change under a run); preview speaks in tracks only (no ground drop lines, 10 s lead-in, cutout dot at the cutout) with a legend (Flown solid blue, New guess solid purple, Actual dashed blue, Current dashed grey when changed) and a chevron+dot carousel instead of the dropdown (swipe stays with rotate); previous tune's guess drawn from the same masks; share/import moved to a dialog; overview and wizard bodies back in `AppCard`s. Monitor screen deleted (`monitor_screen.dart`, router entry, shell slot; link button → Dashboard with updated tooltip; `ChannelHealthMonitor` + exclusive widgets removed from the tile file, `_windowMs` hoisted to `_RateChart`); tile untouched. Tests (8 lab: overview, flow, landed exclusion, old-tune viz + carousel paging on an under-reading flight, discard, share load path, manual ×2). `flutter analyze` clean, **350 green root + 50 green package = 400 total**.
- Iteration fixes 3 (user: solid actual, drop old tune + facts, honest numbers, minimal home): actual continuation now solid pink (was dashed blue, invisible against the input) with matching legend; previous-tune track deleted (model, pass, paint, legend); fixed a real units bug the confusion exposed — headline scores (0–100) were displayed as metres and the verdict subtracted backwards, now mean metres throughout with phase rows deleted; flight facts line deleted; overview is a centered Dead reckoning headline + share string with copy + paste-and-load inline (share dialog deleted) + Generate/Manual doors, no factory/tuned distinction, no paragraphs; Flight Back → Close, Results Back removed with Discard exiting to overview; scroll resets to top on every step change. `flutter analyze` clean, **350 green root + 50 green package = 400 total**.
- Iteration fixes 4 (user: morphing tune line, centered rail, no coverage text, lean results, solid actual, split files): overview is one tune line whose button morphs copy → apply on paste (truncating, no linebreaks) under a Copy / Paste tune label; wizard rail vertically centered with independently scrolling content (LayoutBuilder-bounded row); coverage line and flight facts deleted; results show only comparison rows + legend + preview + buttons (verdict sentences, subtitle, ring caption, transition note, phase rows deleted); actual track and legend swatch now solid pink; previous-tune track deleted; lab split into `dead_reckoning_lab_tab.dart` + `dead_reckoning_lab_preview.dart` + `dead_reckoning_manual_dialog.dart` (recordings-screen precedent). `flutter analyze` clean, **350 green root + 50 green package = 400 total**.
- Iteration fixes 5 (user: morphing line, centered rail/cards, no coverage text, lean results, solid actual, split files): overview is one tune line under Copy / Paste tune whose button morphs copy → apply on paste (truncating single line), Generate + Manual doors, no factory/tuned text, no cards; wizard rail vertically centered with independently scrolling content, step cards horizontally centered, rail node circles vertically centered with side padding; coverage line and flight facts deleted; results show only comparison rows + legend + preview + buttons; actual track and legend swatch solid pink (previous dashed was a leftover); previous-tune track deleted; transition notes deleted (unscored outages never preview); lab split into tab + preview + manual-dialog files. `flutter analyze` clean, **350 green root + 50 green package = 400 total**.
- Multi-length outages + weighted tuning (user: keep Dart, tweak precision, preview longer/shorter): masks cycle 5/15/45 s tiers over the period grid (longs fall back to 15/5 s when they'd swallow the next slot or overrun the flight; 15 s phase top-up; one 45 s window in the longest scorable phase when the flight ≥120 s fits it); tuning objective is the duration-weighted rotation-invariant mean (`deadReckoningGapWeight`: 15 s weighs 1, 5 s weighs 3, 45 s weighs 1/3) with weighted vertical RMSE in the comparison rows; optimizer sweeps velocityScale in 0.05 steps incl. 1.25/1.4 plus an accelerationTracking on/off sweep; preview labels carry the window length and previews run with the same terrain as tuning.
- Overview + zero-knob lab (user: state-first home, always synthetic, drop Landed): page opens on the current tune + manual form + Generate new tune; wizard rail is Flight → Outages → Results (Tune node deleted); all outage settings deleted (segmented control, three sliders, real-gap mode, fallback note, `_FieldSlider`, stale machinery) — one adaptive synthetic scheme (period = duration/6 clamped 15–60 s, 10 s windows, phase top-up, cap 12); Landed/Idle/Armed/Unknown excluded from uniform masks, top-ups, facts and phase rows (`_scorablePhase`); applying returns home with an applied confirmation; scenario rows skip Landed defensively. Measured on `crc26_cleanedup_trim.bin`: 7 automatic masks, within-phase mean ~1 m. Tests rewritten (6: overview, guided flow, landed exclusion via mixed-phase debug flight, discard, manual ×2). `flutter analyze` clean, **348 green root + 50 green package = 398 total**.
- Stepper rebuild (user: long page tried and disliked — make it visual, state-reflecting, hierarchical): the page is now a left step rail (Flight → Outages → Results → Tune) with live node states (numbered ring current, filled check done, warning stale, faint locked/upcoming) plus one-line statuses, hairline connectors, tap-to-jump on unlocked steps; the right pane shows one step with headline + Back/Continue flow. Running auto-advances to Results, applying lands on Tune; config-signature stale detection disables Apply (replaced by Run again) with rail + body warnings; loading a new flight clears results; vertical errors now scored on within-phase masks only. Tests caught a real 4.5 px dropdown overflow (fixed by shortening items + label line below) and now assert rail mirroring (6 tests: rail states, guided flow, stale gate, discard, manual ×2). `flutter analyze` clean, **348 green root + 50 green package = 398 total**.
- Connector refactor (user: split internal representation from parsing; plug-n-play connectors in the shared package; per-connector FSM/commands/events; connector toggle in settings; recordings stamp the connector; migrate old files, drop old support): current 52 B packet shape is now the internal `TelemetryFrame` (SI units) emitted by `packages/serial` and consumed by the UI — raw bytes never leave the package. New `packages/serial/lib/connectors/`: `connector.dart` (`TelemetryConnector`: id/displayName/description, `createParser()` bytestream→frames, states with label/ARGB color/airframe flags/pipeline flag, commands + state-request bytes + describe, event defs, `FieldCapabilities`), `registry.dart` (`allConnectors`, `connectorById`, `defaultConnectorId='mock'`), `mock_connector.dart` (the old format as `mock`: full frame, 9 states, 5 commands + set-state, 4 nominal events). Worker emits `TelemetryFrame` (`PacketReceivedEvent.frame`, `frameStream`); `ConnectCommand`/`StartRecordingCommand` carry `connectorId`, new `SetConnectorCommand`; `SerialWorkerStatus.connectorId`. Recordings are v3 (`TCR3`, 168 B, connector id 32 B @136, directory CRC over 108..131+134..167): `Recorder.start`/`finalizeRecordingFile` require `connectorId`; `FileParser.parseFile` takes a connector; `RecordingRepository.loadReplay` resolves the stamp (unknown → null); replay auto-selects the recording's connector in-memory and restores on stop (`ReplayState.connectorId`); trim preserves the stamp; `buildChannelProfile` takes the connector. App: `connector_provider.dart` (`activeConnectorIdProvider` persisted `trycatch.connector_id` + `activeConnectorProvider`), settings CONNECTOR card (RadioGroup, locked during replay), `SerialConfigNotifier.setConnector` (persist + worker switch; store resets itself on id change), `TelemetryStore.ingest/ingestFrames` take frames, `detectFlightEvents` takes the connector's event table (`FlightEvent` carries label/transitionLabel + nullable style type with flag fallback), FSM tile/control panel/commands tile/3D/nosecone resolve via the active connector, capability gates (`ConnectorGate.unsupportedPlaceholder` → `NotProvidedByConnector`) on altitude/velocity/accel/battery/hall/stats/highlights/max-alt/FSM/nosecone/events/dead-reckoning tiles (map/3D degrade gracefully via site/pad fallback, ungated). `tool/migrate_recordings_v3.dart` replaced the v1→v2 tool; all 8 on-disk recordings migrated (verified: 4138/26214/… frames match header counts, 13-command log intact, `.v2.bak` backups). Tests: new `connector_test` (6), connector-events cases, v3 header cases (v2 rejection, corrupt connector id), all suites updated to frames/connector params. `flutter analyze` clean, **396 green root + 50 green package = 446 total**. Known follow-up: dead-reckoning lab phase names (`dead_reckoning_lab_masks.dart`) still assume the MOCK flight profile.

- AXTree global opt-out (user: console spam, no screen reader needed, drop per-component overrides if obsolete): root `ExcludeSemantics` in `MaterialApp.builder` (`lib/main.dart`) publishes an empty AXTree, silencing `accessibility_bridge.cc(114)` at the source; visual tooltips unaffected. Deleted all per-widget `ExcludeSemantics` (CenteredValue, ChartValueHeader, TimeSeriesChart, channel charts, packet-rate, link-stats, rec-timer, playhead clock, battery discharge, map attribution/legend, PositionReadout, highlights, events/commands clocks, FSM compact label, lab preview) + all `Semantics(container:true)` (playback buttons, FSM/control grids) + `test/tab_tooltip_semantics_test.dart`; scrubbed stale AXTree/182444 comments (kept leaf-consumer splits as perf, kept reset unfocus). `flutter analyze` clean, **395 green root + 50 green package = 445 total**.

- ARM LoRa hang, recurrence (user: connecting to the local LoRa on an ARM machine bricks the dongle until unplug/replug; other software triggers it too): the port open left modem lines + flow control at OS/driver defaults, which on ARM builds asserts DTR/RTS or enables RTS/CTS — holding the 3-wire LoRa MCU in reset / stalling TX on floating CTS until USB re-enumeration. `SerialHardwareConfig` now pins the line policy (flowControl none, RTS/DTR off, CTS/DSR ignore, XON/XOFF disabled); `RealSerialPort.connect()` applies 8N1 + policy in a single atomic `sp_set_config` (was 4 per-field round-trips, each able to pulse the lines) and flushes open-time glitch bytes before attaching the reader. New pinning test `test/serial_line_policy_test.dart`. `flutter analyze` clean, **421 green root + 50 green package = 471 total**.

- Serial toasts + half-open link fix (user: HW link sometimes receives but can't send, failures silent, port state stale; want error toasts + disconnect state in UI; check cross-platform funk): root causes found and fixed — (1) `SerialWorker._handleMessage` swallowed every `ErrorEvent` with a bare `print()`, so connect failures / port errors / send failures never reached the UI; (2) `worker.dart onDone` was silent (no error, status flip only) and `RealSerialPort` never propagates native handle loss (broadcast byte controller never errors/closes), so a yanked adapter left status stuck at "connected" with no packets; (3) failed `SendBytes` never flipped status, so the UI stayed half-open (RX ok, TX dead) and kept dispatching. Fixes: `SerialWorker` now exposes `errorStream` (+ `serialErrorsProvider`); worker gains `markDisconnected()` (teardown + status flip + `ErrorEvent`), a 500 ms disconnect watchdog reconciling `status` vs `service.isConnected`, `onDone`/`onError` both funnel through it, `SendBytes` failure on a dead handle flips to disconnected, `ConnectCommand` catches FFI throws and always pushes a disconnected status + detailed error, port scans are isolate-safe (`safePorts()`); `RealSerialPort.availablePorts` + `SerialService.availablePorts` never throw (Linux/macOS permission/udev quirks), partial writes tear the port down instead of lingering half-open. UI: new `lib/state/toast_store.dart` (bounded queue, consecutive-dupe refresh), `lib/ui/components/toast_overlay.dart` (bottom-right cards, severity colors/icons, 4–6 s auto-dismiss + manual close, dark-mode safe), `lib/ui/components/serial_toast_bridge.dart` (headless; errors → error toast, connected→disconnected → warning toast, failed uplink → "Command failed" toast with resolved label), both mounted in `AppShell` over the workspace. New tests `toast_store_test` (5), `toast_overlay_test` (4), `serial_toast_bridge_test` (4 + ErrorEvent timestamp). `flutter analyze` clean, **435 green root + 50 green package = 485 total**.

- Silent-connect cast bug + toast policy (user: connect to COM4 does nothing — no error, no state change; manual disconnect needs no toast): the user's stack trace nailed it — `manager.dart:110` destructured `ErrorEvent(:final message)` (a `String` field) then cast it back (`message as ErrorEvent`), throwing on every worker error so `errorStream` stayed empty forever; the COM4 failure additionally pushed an unchanged disconnected status, hence "no state change". Fixed with `case final ErrorEvent errorEvent` forwarding the intact event, pinned by new `test/serial_worker_error_test.dart` (spawns the real isolate, failed connect must yield an `ErrorEvent` — red before, green after). Bridge no longer toasts on status flips at all: `DisconnectCommand` emits no error so manual disconnects are silent (pill flip is the signal); unexpected loss still toasts via its `ErrorEvent`, classified as a "Port disconnected" warning (`isDisconnectMessage`), everything else stays "Serial error". `SerialControls` link segment is now always tappable — no-port taps toast "No port selected" instead of dying silently — and `SerialConfigNotifier.connect()` toasts the same hint on a null port. Bridge tests updated (status-only flip stays silent, disconnect-text error → warning). `flutter analyze` clean, **437 green root + 50 green package = 487 total**.

- Connecting pill + rescan toast + worker hardening (user: failed connect takes a moment with no feedback — want a connecting state; also a ports-refreshed toast): `SerialConfig` gains `connectingPort` (optimistic, set in `connect()`) and `refreshPending`; the pill shows a 14 px spinner + `PORT…` + pink border while in flight, with "Connecting to X…" tooltip; mid-connect and no-port taps toast hints (never a dead click). Cleared on connected status ([SerialControls] listener), on any error ([SerialToastBridge] listener), or a 10 s timeout. `refreshPorts()` arms `refreshPending`; the bridge toasts exactly one "Ports refreshed — N found" (warning variant when empty) per explicit rescan. Two deeper finds while testing: (1) `ref.listen` outside a widget `build` does not reliably deliver stream events (probed: provider stuck `AsyncLoading` despite live streams), so the notifier holds zero subscriptions — all worker subscriptions live in widget builds; (2) `SerialWorker.send()` before the isolate handshake silently dropped commands in release (assert only fired in debug) — `send()` now buffers to an outbox flushed on handshake, plus a public `ready` future; all event-controller adds are `isClosed`-guarded (late isolate messages raced `dispose` and threw `Bad state`). New `test/serial_connecting_test.dart` (5: failed/MOCK/rescan/mid-connect-tap/`isDisconnectMessage`; widget-driven with `runAsync` waits — `testWidgets` fake-async freezes polling loops). `flutter analyze` clean, **442 green root + 50 green package = 492 total**.

- MOCK-DC chaos port (user: add a mock that disconnects / fails to connect randomly, to test this): new `packages/serial/lib/hardware/mock_dc.dart` (`MockDcSerialPort`, `MOCK-DC`) — same flight + interference cycle as MOCK, plus three tunable chaos rates (defaults: ~30% refused opens, ~25 s mean hard drop that stays down until reconnect, ~10% uplink NAKs while staying connected). Exercises the connecting pill, error/disconnect/command-failed toasts, and the watchdog path with no hardware. `SerialService` routes it everywhere MOCK/MOCK-BQ go (availablePorts dev listing, `isMockPortName`, `isConnected` with its own branch — previously a new mock would have fallen through to the wrong port's state — connect/disconnect/sendBytes) and re-exports it; picker/release-filtering pick it up automatically via `isMockPortName`. New `test/mock_dc_test.dart` (8, FakeAsync + 0.0/1.0 pinned rates: naming, listing, sane defaults, refused open, clean-link behavior + reconnect, first-tick drop with no recovery, send NAK/ACK/down matrix, luck-independent `SerialService` routing). README + `docs/data-flow.md` + HANDOFF §3.4 mention it. `flutter analyze` clean, **450 green root + 50 green package = 500 total**.

- Hot-restart zombies: tray dupes + ports stuck open (user: `flutter run` + hot reload duplicates the tray icon, opened ports stay open in the old process): two mechanisms. (1) Ports: child isolates survive a hot restart holding the serial handle, and `IsolateNameServer` (the classic kill-by-name channel) is gone from this SDK entirely — so the worker now runs a liveness lease instead: every received command renews it (`workerLeaseMs` = 8 s, pure `workerLeaseExpired` predicate), `main` pings every 2 s (`PingCommand`, ack-free), and the 500 ms stats tick self-exits (ports released, recording finalized, inbox closed) past the lease — a zombie squats at most ~8 s, then reconnects work. `SerialWorker.send` also buffers pre-handshake commands (outbox + `ready`) instead of silently dropping them in release, and all event-controller adds are `isClosed`-guarded (late isolate messages raced `dispose` and threw `Bad state`). (2) Tray: each `TrayIcon.create()` is a fresh OS entry with no global destroy, so a restart-orphaned icon is undisposable from the new isolate — setup is now idempotent (dispose-before-create, guarded dispose) and documents that limit; ghosts are dev-only (production never hot-restarts). Tests: `serial_worker_lease_test` (3: predicate + live unpinged-worker release/silence), keep-alive pings in the worker-spawning suites. Note: `ref.listen` outside a widget `build` proved unreliable for streams, and `testWidgets` fake-async freezes polling loops — worker tests stay widget-driven with `runAsync` waits. `flutter analyze` clean, **453 green root + 50 green package = 503 total**.

- Windows cnativeapi warnings (user pasted MSVC C4267×6 + C4996×2 from the tray plugin's native code on ARM64): third-party noise, not our code — the plugin sets no warning flags itself (inherits CMake's `/W3`) while our targets are `/W4 /WX`. `windows/CMakeLists.txt` now appends `/wd4267 /wd4996` to the `nativeapi`/`cnativeapi` targets only (Linux-precedent pattern, `if(TARGET ...)`-guarded), verified with `flutter build windows --debug`: **0 warnings**. Note: the same build exposed an unrelated environmental failure — CMake install cannot overwrite `cnativeapi.dll` with `Permission denied` because a `trycatch.exe` instance is currently running (tray-hidden per the hide-on-close design); quit it and rebuild. No test changes, count stays **503 total**.

- Sonner-style toast motion (user: animate toasts like shadcn's sonner): `ToastOverlay` is now an `AnimatedList` synced to the store by id diff (removals high-to-low, ordered inserts, in-place dedupe refreshes) — cards enter with slide-up + fade (350 ms `easeOutCubic`), exit with slide-down + fade + collapse (250 ms), survivors glide to fill the gap; ordering flipped to sonner bottom-right (oldest top, newest lands at the bottom edge). Same `_AnimatedToast` tween serves both directions (list runs it 0→1 / 1→0). Fixed while there: the empty-state `SizedBox` orphaned later inserts (no list state to animate into) — the list now always builds. `toast_overlay_test` 4→8 (cap newest-last, slide-in settle, tap + programmatic dismiss with mid-exit presence, newest-below ordering). `flutter analyze` clean, **457 green root + 50 green package = 507 total**.

- Tray-dupe diagnostics (user: still 2 tray icons on hot reload): same-process double-create is ruled out — reload only `reassemble`s (framework source confirms state/`initState` untouched), so our `create()` cannot re-fire on plain `r`. With one live process observed, the second icon is either a hot-restart (`R`) orphan (isolate torn down with no teardown; undisposable cross-isolate — plugin has no global destroy) or a dead-process Windows ghost (vanishes on hover). Added `kDebugMode`-only lifecycle tracing to pinpoint it: `[app] main() ran` (restart marker — reload never re-runs `main`), `[tray] icon created id=…`, `[tray] dispose icon`. No test changes.

- Lazy tray icon (user confirmed: second icon appears only after hot restart): since a restart-orphaned icon is undisposable cross-isolate, the fix is to create fewer icons — the tray icon is now lazy, materializing on first window-hide (`_ensureTrayIcon`, concurrent hides share one in-flight setup) instead of at startup, so the pure build/run/restart dev loop never creates one (at most one ghost per hide+restart cycle). `onWindowClose` hides only behind a live icon and quits outright otherwise (hiding icon-less would strand the app with no UI). `flutter analyze` clean, full suite green, count stays **507 total**.

- Dev tray off + restart-handoff proof (user: disable the tray icon in dev, it's unneeded; check ports aren't held across hot restart): `_initDesktopLifecycle` returns early under `kDebugMode` — no tray icon ever, no `preventClose`, native close quits the process (ports freed, zero orphans). Release keeps hide-on-close with the lazy icon; `onWindowClose` quits outright if icon creation fails instead of stranding an invisible app. Ports: new `restart handoff` group in `serial_worker_lease_test` models the restart exactly (old worker connected then unpinged, replacement spawned + pinged) and proves the old worker reports the link down while the replacement keeps flowing on the same port name — same `service.disconnect()` path real ports use, so exclusivity is released too. `flutter analyze` clean, **458 green root + 50 green package = 508 total**. Manual check on hardware: connect a real port, hot-restart, reconnect — must succeed (≤8 s worst case) with no "Failed to open".

- Slow `flutter run` + C1090 PDB lock (user: builds take very long; first build hung on `error C1090: PDB API call failed, error code '5'` then LNK4099 spam on retry): two stacked causes. The 168 s rebuild was one-time fallout of the warning-suppression flag change (new compile flags = every cnativeapi TU recompiles) — incremental builds are fast again after it. The hang was a locked `nativeapi.pdb` (stale mspdbsrv/lock, error 5 = access denied); aborting mid-build then left a PDB-less lib behind, hence the LNK4099 noise. Added `/FS` to the same per-target suppression block (serializes PDB writes through mspdbsrv — the textbook C1090 fix). Costs one more full plugin recompile now, which also regenerates the PDB and ends LNK4099. No test changes, count stays **508 total**. If it recurs: quit the running app first (locked DLLs fail install the same way) and kill stray mspdbsrv.exe; never run two builds at once.

---

## Part 9 — Design Decisions

- Wire formats live behind connectors; each connector's framing is a placeholder until its real firmware lands — CRC keeps it honest. Add a connector = one class + one registry entry.
- Tiling only: everything fits the viewport, no page scroll, no holes.
- Charts show raw data, one shared code path. Modular/data-driven tiles.
- Debug builds are janky — evaluate with `flutter run -d <os> --release`.
- **Do not start the app yourself.** Ask the user for screenshots/descriptions.
- FS-backed screen widget tests are impossible: `initState` always runs in the fake-async zone where `path_provider` + `Directory.list` stall permanently.
- AXTree spam (Windows `accessibility_bridge.cc(114) Failed to update ui::AXTree`): fixed by global opt-out — root `ExcludeSemantics` in `MaterialApp.builder` (`lib/main.dart`), per-widget mitigations deleted. No Narrator/screen reader in use; app intentionally exposes no semantics.
