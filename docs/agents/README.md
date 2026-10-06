# Agent guide — read before touching state, time-series, or tiles

## 1. Stores: two bases, two verbs

* `lib/foundation/store.dart` owns `SessionStore` (in-memory) and
  `PersistedStore` (SharedPreferences + JSON).
* Session buffers: extend `SessionStore`, implement `void clear()`.
  Never touch disk in `clear()`. Never throw. Idempotent.
* Persisted settings: extend `PersistedStore`, define `prefsKey`,
  `defaults`, `fromJson`, `toJson`. Never call `SharedPreferences`
  directly — use `loadPersisted()` / `save()` / `resetToDefaults()`.
* Timers: mix in `StoreTicker`, `startTicker` in `build()`,
  `cancelOnDispose(ref)`, `stopTicker()` first in `clear()`.
* CopyWith: sentinel `_absent` for nullable-clear fields
  (see `LaunchSiteState`). Plain `??` must not be used where null
  means "clear".
* Forbidden: `reset()` / `stop()` synonyms on new code (legacy aliases must be removed when their consumers migrate), barrel re-exports across state files,
  `ref.listen` outside `build()`, per-widget private trackers.

## 2. Flight clear: one entry

* `lib/session/flight_reset.dart` `FlightReset.clearFlight(ref)` is the
  only Clear-buffers path. Order: replay, telemetry, commands, channel.
* Toasts are feedback, not flight — never cleared here.
* Adding a flight-scoped store: extend `SessionStore`, add one line to
  `FlightReset`, and cover it in `test/app_flows_test.dart`.
* `settings_screen.dart` Clear dialog calls only `FlightReset`. No direct
  `telemetry.reset()` + `commandLog.clear()` pairs.

## 3. Time-series: one interface

* `lib/foundation/time/` owns `TimeSeries` (chronological 0=oldest),
  `RingTimeSeries` (live, bounded), `ListTimeSeries` (replay/preview),
  `decimate()` (`extremes` for charts, `strideStable` for trails/maps),
  `rateOverWindow()` (exact cumulative mean over a window — displays use
  this, never one instantaneous slice), `RateSeries` (link rates from
  `LinkStats`).
* UI never indexes `RingBuffer` (`[]`/`getChronological`/`newestFirst`)
  directly — use `oldest/newest/slice/splitAt/toChronological`.
* Played/future split: `splitAt(clockMs)` + carry-last-point in the
  widget. No hand-rolled `playedRaw/futureRaw` loops.
* Position-pure readouts (FSM time-in-state, state progress) come from
  `core/flight_states.dart` (`segmentAt(context)`) — never from ingested
  history, so seeks and speed cannot perturb them.
* New time-varying data: add `timestampOf`, pick capacity in
  `AppConfig`, choose `Decimation`, reuse `RateSeries.label()`.

## 4. Feedback: toasts only, via AppFeedback

* `AppFeedback` / `ref.*Toast` (`lib/session/feedback.dart`) is the
  single entry over `toastStoreProvider`. Never push to the store
  directly outside it. Repeats stack as separate cards (shadcn-style, no
  dedup); the queue caps at `maxEntries`.
* Style: title is a short Title Case noun (`Serial error`,
  `Port disconnected`, `Command failed`, `Ports refreshed`); the message
  is one plain sentence naming ports/files/counts exactly once, ending
  with the next step (`check the cable and retry`, `select a port
  first`). Worker messages follow the same rule at the source
  (`packages/serial/lib/worker/worker.dart` names the port once).
* Severities: success (confirmations), warning (no-result searches,
  disconnects), error (failures), info (neutral notes + undo).
* Undo flows: `push(message, actionLabel: 'Undo', onAction: ...)` —
  the card runs the callback then dismisses. Pinned by
  `toast_overlay_test.dart` (action button test).
* Diagnostics: `AppLog.warn` (debug-only). No raw `print`/`debugPrint`
  in `lib/`.

## 5. Recording I/O: one door

* `RecordingRepository` (`loadReplay`, `decodePreview`, trim via
  `flight_trim.dart`) is the only entry UI/state may use. Never import
  `FileParser` / `readRecordingChunks` / `decodeRecordingFrames`
  outside `services/`.

## 6. Tiles: one contract (migrating)

* Every tile: `ConnectorGate` -> `WaitingForData` -> content.
  No custom "no data" text, no missing empty state.
* Watch narrowly: `select(positionMs/isActive)` for ticker fields
  (see `map_tile.dart`, `events_tile.dart`). No full
  `watch(telemetryStoreProvider)` in new tiles.
* Charts: use `TimeSeriesChart` for telemetry. Channel-profile rendering
  uses bins and shares axis/touch helpers; rates use `RateSeriesView`.
* Dialogs: one `AlertDialog` shape — title, body, `TextButton` Cancel +
  `FilledButton` confirm (destructive confirms use `AppColors.destructive`).
* Two-click confirm (`control_panel`, `fsm`): use `TwoClickButton` and its
  group controller; dispose the controller with its owner.
* Theme: `AppColors`/`AppText` only. `Colors.*` outside `theme/`
  fails review.

## 7. Comments + names: timeless, consistent

* Comments describe what the code IS and its contract, as if written
  before the file in one go. Never the edit history: no "previously X",
  "used to Y", "now Z", "fixed so ... works", first-person notes, or
  per-iteration change summaries. Rationale longer than 2 lines goes in
  `docs/architecture.md`, not inline.
* After an edit, re-read the touched comments: any sentence the change
  made false or historical gets rewritten or deleted in the same edit.
  No orphan references to deleted code paths.
* One concept, one word, everywhere: `clear()` (session buffers) vs
  `resetToDefaults()` (persisted settings); `played`/`future` splits;
  `oldest`/`newest` indexing; `RateSeries`, `FlightReset`, `TimeSeries`.
  New code reuses the existing term instead of coining a synonym.

## 8. Quality gates

* `flutter analyze` clean, `flutter test` green before handoff.
* New stores/time-series need unit tests (clear idempotence,
  corrupt-prefs fallback, decimation stability).

## 9. E2E tests: container harness rule

* `test/app_flows_test.dart` drives the real worker isolate + MOCK port
  with no widgets. Bare-container `read` does NOT drive StreamProviders
  (status/frames/link-stats stay loading) — the harness must attach
  `container.listen(...)` on every worker-derived stream (same root cause
  as the widget-harness NOTE in `serial_connecting_test.dart`).
* New worker-dependent flows go in `app_flows_test.dart` (shared
  spawn + ping in `setUpAll`, fresh container per test, connect/disconnect
  per test, temp dirs cleaned in `finally`).

## 10. Known exceptions (do not "fix" without a task)

* 3D tiles render on the GPU only (`lib/ui/tiles/shared/gpu/`, see
  `docs/3d-rendering.md`). There is no CPU painter fallback: a new 3D feature
  goes through the GPU builders. Geometry/stream conversion helpers stay
  engine-free so they remain unit-testable, and world-space annotations ride a
  thin 2D overlay that reuses the shared camera (never re-derive the camera).
* Windows' global ExcludeSemantics is intentional; see `docs/architecture.md`.
* Public serial package APIs (`FileParser`, `recordingBodyOffsetOf`) retain
  test coverage even when the app's repository uses lower-level readers.
* `ToastStore` ids are per-launch ints (ephemeral, dismiss identity);
  persisted entity ids use `Ids.next(prefix)`.

## 11. Runtime boundaries

* Select a launch site before any connection, recording or command action.
  Disconnect/stop remain available for recovery.
* `TelemetryState.history` and channel series are read-only live views;
  mutation stays in their SessionStore. Preserve revision changes on writes.
* `RecordingRepository` runs at most two bulk decodes off the UI isolate.
* Terrain mesh and GPU-stream conversion use isolates; textures stay on the
  engine, with a bounded atlas and serialized upload. See `docs/3d-rendering.md`.
* Workspace defaults generation lives in `tool/workspace_codegen.dart`;
  the debug UI invokes validated tooling from the repository root.
* Architecture and lifecycle ownership are documented in `docs/architecture.md`.
