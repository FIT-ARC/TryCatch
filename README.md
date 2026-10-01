# TryCatch

Ground station for model rockets — _ARC@FIT_.

A Flutter desktop app that receives live telemetry from a rocket over a serial link, displays it on a tileable dashboard, records flights to disk and replays them, and sends commands back to the rocket.

No hardware? The built-in **MOCK** port runs a full-flight simulator (pad → ascent → apogee → parachute → landed), so the whole app works without a rocket.

## What it can do

- **Live telemetry** — 10 Hz serial frames, parsed and CRC-checked in a background isolate.
- **Tiling dashboard** — hyprland-style workspaces with drag-to-resize splits, drag-to-swap tiles, and per-workspace persistence. Factory presets: Flight control, Pre-flight check, Recovery, Replay.
- **Telemetry tiles** — altitude / velocity / acceleration / battery / hall-sensor charts, GPS + dead-reckoning map, 3D rocket attitude, 3D flight path (plain + satellite), flight-state machine, GPS position, dead-reckoning estimate (packet loss only, live only), max altitude, nose-cone lock state, and a command panel.
- **Recording & replay** — one-click recording to `Documents/TryCatch/recordings/*.bin`, with seek + speed + loop control on replay (Space toggles pause/play). Recordings carry launch site, time span, packet count and peaks in the file header. The playback bar has a display-smoothing toggle (3D trail + rotation, off by default); recordings, charts and map stay raw.
- **Sample flights** — drop `.bin` recordings in `assets/recordings/` to ship them with the app; they appear in Recorded flights as read-only bundled samples (replayed straight from the asset, never copied to disk).
- **GPS gap filling** — ground-side dead reckoning bridges GPS outages so tracks stay connected.
- **Dead reckoning tuning** — its own screen: guided re-tune against a flight recording (one 0–100 score per tune, per-phase breakdown, rotatable 3D outage preview), apply live or share as a short string.
- **Channel health** — checks whether your frequency is free before launch (clear / activity / interference), mirrored live in the top bar.
- **Command uplink** — send commands to the rocket with two-click confirmation for arming/pyro.

> ⚠️ The wire format and command bytes are **placeholders** until the real flight software exists. They are CRC-checked, but **must be aligned with the real firmware before flight**. See `packages/serial/lib/telemetry/frame_codec.dart`.

## Install (recommended)

Download the latest release from **GitHub Releases**. One release contains all platforms:

| OS                  | Files                                                                         | How to install                                                                                                                                                                                                                                                                                                   |
| ------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows x64 / ARM64 | `trycatch-<ver>-windows-*.msix` (+ `trycatch-signing.cer`) or `-portable.zip` | MSIX: install `trycatch-signing.cer` once (double-click → Install Certificate → Local Machine → Trusted People, App Installer must be enabled), then install the matching `.msix`. SmartScreen will warn on first run (expected, self-signed). No cert / unsigned? Extract the `-portable.zip` and run directly. |
| Linux x64           | `TryCatch-<ver>-x86_64.AppImage` or `trycatch-<ver>-linux-x64.tar.gz`         | `chmod +x TryCatch-*.AppImage && ./TryCatch-*.AppImage` (needs FUSE). For real serial hardware: `sudo usermod -aG uucp $USER` then log out/in; optional udev rules (`69-trycatch-serial.rules`) ship with the release.                                                                                           |
| macOS arm64         | `TryCatch-<ver>-macos-arm64.dmg` or `.zip`                                    | Open the DMG, drag to Applications, first launch via Right-click → Open (ad-hoc signed, no paid Apple account). Intel Macs run through Rosetta.                                                                                                                                                                  |

Verify downloads with `SHA256SUMS.txt` in the release.

## Quick start / how to use

1. **Connect** — pick a port in the top bar and hit **Connect**. Use `MOCK` for the simulator (`MOCK-BQ` is the same flight but cuts out for ~5 s every ~15 s to test link-loss behavior; `MOCK-DC` randomly refuses opens, drops the link, and NAKs uplinks to test failure toasts; `Brno` is a static pad at 49.22892339, 16.58285375 that toggles parachute on/off every 5 s for testing downstream software), or the rocket's serial port for real hardware.
2. **Set a launch site** — open Settings → LAUNCH SITE and pick a saved site (or save the rocket's current GPS as one). Recording stays disabled until a site is set, and the site locks while recording.
3. **Arrange the dashboard** — toggle **Edit layout** to drag dividers, swap tiles by dragging them onto each other, double-click a divider to flip horizontal/vertical, or use Add-tile / per-tile split. Tabs (`Ctrl+1..9`) are separate workspaces.
4. **Record** — hit **Record** in the top bar during a live session. Files land in `Documents/TryCatch/recordings/`.
5. **Replay** — open the Recordings screen, pick a flight (stat grid + 3D previews), hit play. Use the playback bar for seek/speed/loop, Space for pause/play, **Back to live** to exit.
6. **Check the channel** — open the Monitor screen before launch. If it says interference, change frequency.
7. **Send commands** — use the command panel tile (disabled while disconnected or replaying). Arming/pyro need a second confirm click within 3 s.

Tips:

- Charts show a 60 s rolling window live, the whole flight on replay.
- Map/3D tiles are immersive — use the tool buttons for follow, satellite, zoom, and camera mode.
- Dark mode, offline-map preload, and saved sites live in Settings.

## Run from source

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) (stable, see `FLUTTER_VERSION` in `.github/workflows/ci.yml`) with desktop support for your OS, plus on Linux: `ninja-build libgtk-3-dev pkg-config cmake clang liblzma-dev`.

```powershell
flutter pub get
flutter run -d windows --release   # or -d linux / -d macos
```

Use `--release` — debug builds are janky and misrepresent performance. Then pick the `MOCK` port and hit **Connect**.

Baud rate and framing live in `packages/serial`.

## Project layout

```
lib/
  foundation/       shared bases: SessionStore/PersistedStore, TimeSeries +
                    decimation + RateSeries, Ids, chart axes, logging
  session/          cross-store flows (FlightReset clears every flight buffer)
  state/            Riverpod stores (telemetry, replay, workspaces,
                    launch sites, connector, channel health, toasts)
  ui/screens/       app shell + screens (dashboard, recordings, settings,
                    monitor, dead-reckoning lab)
  ui/components/    shared chrome (top bar, cards, pills, toast overlay)
  ui/tiles/         registry + 19 tiles + shared/ (charts, 3D scene, tile I/O)
  ui/tile_registry.dart  data-driven tile descriptors (new tile = one class
                    + one entry)
  services/         RecordingRepository (sole recording I/O door), trim,
                    elevation, prefs keys
  core/             pure logic (format, flight events/stats, ring buffer)
  theme/            "Precision Light" design system
packages/serial/  connectors, framing, codec, worker isolate, mock simulator
packages/dead_reckoning/  estimator + tune + eval + geo (pure Dart)
test/             unit + widget + end-to-end (`app_flows_test.dart` drives
                  the real worker isolate over the MOCK port)
docs/agents/      contributor conventions (read before changing state/UI)
packaging/        linux desktop/udev files; windows MSIX via package:msix
```

Deep-dives: [HANDOFF.md](HANDOFF.md) (history + decisions) and
[docs/agents/](docs/agents/) (current conventions for state, time-series,
tiles, feedback, and tests).

## Contributing

Issues and PRs welcome.

1. Fork, branch off `main`, open a PR against `main`.
2. Keep it focused — one feature/fix per PR, describe how you tested it.
3. Keep the checks green:

    ```powershell
    flutter analyze
    flutter test
    ```

    CI runs the same two steps; releases are gated on them too.

4. Follow existing conventions (see [docs/agents/](docs/agents/) — required
   reading before changing state, time-series, tiles, or feedback):
    - Riverpod 3, no codegen, no router package, no `build_runner`.
    - Stores extend `SessionStore` (in-memory, `clear()`) or `PersistedStore`
      (disk, `resetToDefaults()`); "clear buffers" goes through `FlightReset`.
    - Time-varying data goes through `TimeSeries` + `decimate()`; link rates
      through the shared `RateSeries` — no per-widget trackers.
    - One feedback system: toasts only, no `SnackBar`s. Recording I/O only
      via `RecordingRepository`.
    - Keep tiles data-driven — a new dashboard tile is one class + one `TileRegistry` entry (id, title, description, min size, builder).
    - Charts plot raw data through the shared `TimeSeriesChart` path — no per-tile smoothing.
    - Match the Precision Light theme (`AppCard`, `AppText`, pink `#FF00A1` accent only; status stays green/amber/red).
5. If you touch the wire format (`packages/serial`), update the codec, the mock simulator, recording header handling, and tests together — there is a single format with no versioning, by design.

Releases are cut by pushing a `vX.Y.Z` tag (see `.github/workflows/release.yml`).
