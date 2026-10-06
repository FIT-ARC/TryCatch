# Architecture

TryCatch is a Flutter desktop ground station. `packages/serial` owns radio
hardware, connectors, byte framing and recording files. `packages/dead_reckoning`
owns pure position projection. `lib/core` contains domain calculations;
`lib/foundation` contains store, time-series and scheduling contracts;
`lib/services` owns file, network and developer-tool integration;
`lib/state` coordinates session and persisted state; `lib/ui` renders it.

## State and session ownership

Session stores expose `clear()` and never perform disk I/O during clearing.
`FlightReset` is the operator's coordinated clear entry. Replay clear, reconnect
and connector changes also clear the appropriate flight history. Persisted
stores share preference decoding, corrupt-data fallback and save behavior.
ThemeModeStore owns persisted theme selection; AppThemeMode is only a
ValueNotifier adapter for dynamic palette access.

TelemetryStore retains bounded live history and independently accumulates
session peaks and the original start time. History eviction does not reset
those aggregates. TelemetryState exposes read-only chronological TimeSeries
views and a revision for history updates. ChannelHealthNotifier privately owns
RateSeries and publishes a read-only RateSeriesView. Full recordings use
ListTimeSeries. Charts share extrema decimation; trails, maps and previews share
start-anchored stride sampling. Consumers select the fields they display.

## Connection and recording lifecycle

A selected launch site is required before choosing/rescanning a port, connecting,
starting a recording or dispatching uplink commands. Controls show the missing
prerequisite. Disconnect and stop remain available. The site is stamped into
each recording header. Replay uses the recording's site and connector and
disconnects live radio before playback.

SerialWorker runs independently of UI rendering. It owns its receive ports,
reports unexpected exit/error as disconnected status, and has an acknowledged
shutdown that stops streaming, flushes and finalizes the recording, then releases
resources. Desktop quit awaits this acknowledgment. Emergency dispose remains
available for teardown. Worker recording failures report feedback without
terminating telemetry processing. File names include microseconds; Recorder
exclusively creates destinations so an existing file cannot be overwritten.

RecordingRepository is the application's decode entry. At most two background
decodes run concurrently. Replay frame and channel-profile accumulation share
one parser pass. Parsers advance a cursor and compact once per feed. Channel
profiles reject reversed timestamps and adapt bin width to a 20,000-bin budget.
Replay load failures settle into an error state; generation checks discard
stale completions. Whole-flight highlights, events and command positions are
derived from stable recording lists rather than recomputed per playhead tick.

## Views and terrain

Only the active screen is mounted. Session, workspace and channel history stay
in providers; transient view state and timers are disposed when leaving a screen.
TwoClickButton and its group controller share arm/confirm/sent behavior and
timer ownership for command and FSM controls. AppFeedback is the sole toast
entry, and renderer colors live in AppColors.

3D rendering is GPU-only; see [3d-rendering.md](3d-rendering.md). Terrain meshes
and GPU vertex conversion run in isolates. Image decoding and native texture
upload require the Flutter engine, so imagery jobs are limited to two and atlas
uploads are serialized. Atlases are capped at 2 megapixels and 4096 pixels per
dimension, with mip generation disabled. GPU resources are shared between views.
Imagery, DEM and retained terrain caches have bounded entry counts. Eviction
drops cache references; active views retain their patches, and Flutter releases
native image handles when their Dart references are collected. Shared images
must not be disposed while a view still uses them. Temporary codecs, pictures
and decoded tile images are disposed explicitly.

Changing launch sites clears displayed terrain and elevation before the new
scene is resolved. Partial downloads record coverage and are not permanently
cached. Missing imagery/DEM retries with backoff; progressive stages upgrade
without downgrading the displayed terrain. Tile transfers have header/body
timeouts and a 4 MiB response limit.

Windows' global ExcludeSemantics is intentional: telemetry-rate semantics
updates trigger AXTree failures in the desktop bridge. Keep it unless the
underlying bridge issue is addressed and the decision is explicitly revisited.

## Public live bridge

The provider-owned LiveBridgeRuntime forwards live frames to a separate HTTP
isolate and owns its heartbeat, retry timers and ports. It restarts a crashed
bridge and coalesces pre-handshake config/frame messages. Forwarding and server
enablement require a launch site. Replay data is not forwarded.

The bridge serves read-only JSON/SSE. It caps subscriptions at 64, allows one
flush per client with only the latest pending frame, and aborts stalled/expired
sockets. Shutdown force-closes clients. The liveness lease expires even when
sharing is disabled or binding failed, allowing an orphaned isolate to exit.

## Workspace models and developer tooling

Layout constraints live in state metadata, independent of widget builders.
Camera names and labels live in a core enum; icons remain a UI extension.
WorkspaceStore only coordinates model mutations and persistence. The debug
defaults action exports JSON to `tool/workspace_codegen.dart`. The generator
uses fixed safe identifiers, escapes strings and validates/formats a temporary
file before replacing defaults. It runs only from an explicit repository root,
with a runtime debug guard. There is no upward source-file search.

The serial package's FileParser and recordingBodyOffsetOf remain supported
public APIs with tests. A test-only balanced layout builder lives in test
support. Obsolete CPU terrain projection and legacy packet/channel trackers
are retired. The channel profile chart retains its domain-specific bin rendering
and shares axis/touch helpers with telemetry charts.

## Validation

`flutter analyze`, root `flutter test` and `dart test` in
`packages/dead_reckoning` are the local gates. CI runs analysis/tests on pushes,
pull requests and manual dispatch; releases retain their own gate. Architecture
tests pin layer boundaries, colors and state re-export rules. Worker-dependent
container tests keep explicit stream subscriptions; see the agent guide.

Native GPU frame latency still needs on-device profiling: engine uploads cannot
be moved to a Dart isolate. Unit tests validate the pure geometry path and upload
budgets, but do not establish that every hardware/driver combination is free
of loading stalls.
