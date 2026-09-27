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
* Forbidden: `reset()` / `stop()` synonyms on new code (legacy aliases
  remain only for migration), barrel re-exports across state files,
  `ref.listen` outside `build()`, per-widget private trackers.

## 2. Flight clear: one entry

* `lib/session/flight_reset.dart` `FlightReset.clearFlight(ref)` is the
  only Clear-buffers path. Order: replay, telemetry, commands, channel.
* Toasts are feedback, not flight — never cleared here.
* Adding a flight-scoped store: extend `SessionStore`, add one line to
  `FlightReset`, add a case to `test/flight_reset_test.dart`.
* `top_bar.dart` Clear dialog calls only `FlightReset`. No direct
  `telemetry.reset()` + `commandLog.clear()` pairs.

## 3. Time-series: one interface

* `lib/foundation/time/` owns `TimeSeries` (chronological 0=oldest),
  `RingTimeSeries` (live, bounded), `ListTimeSeries` (replay/preview),
  `decimate()` (`extremes` for charts, `strideStable` for trails/maps),
  `RateSeries` (link rates from `LinkStats`).
* UI never indexes `RingBuffer` (`[]`/`getChronological`/`newestFirst`)
  directly — use `oldest/newest/slice/splitAt/toChronological`.
* Played/future split: `splitAt(clockMs)` + carry-last-point in the
  widget. No hand-rolled `playedRaw/futureRaw` loops.
* New time-varying data: add `timestampOf`, pick capacity in
  `AppConfig`, choose `Decimation`, reuse `RateSeries.label()`.

## 4. Tiles: one contract (migrating)

* Every tile: `ConnectorGate` -> `WaitingForData` -> content.
  No custom "no data" text, no missing empty state.
* Watch narrowly: `select(positionMs/isActive)` for ticker fields
  (see `map_tile.dart`, `events_tile.dart`). No full
  `watch(telemetryStoreProvider)` in new tiles.
* Charts: use `TimeSeriesChart` config. Channel tile is migrating to
  it — do not extend its custom `fl_chart` fork.
* Dialogs: use shared confirm helper (coming in `ui/design/`).
  Two-click confirm: use shared `TwoClickButton` (coming).
* Theme: `AppColors`/`AppText` only. `Colors.*` outside `theme/`
  fails review.

## 5. Quality gates

* `flutter analyze` clean, `flutter test` green before handoff.
* New stores/time-series need unit tests (clear idempotence,
  corrupt-prefs fallback, decimation stability).
* Comments: why + invariant + units, 1-2 lines. No iteration essays.

## 10. E2E tests: container harness rule

* `test/app_flows_test.dart` drives the real worker isolate + MOCK port
  with no widgets. Bare-container `read` does NOT drive StreamProviders
  (status/frames/link-stats stay loading) — the harness must attach
  `container.listen(...)` on every worker-derived stream (same root cause
  as the widget-harness NOTE in `serial_connecting_test.dart`).
* New worker-dependent flows go in `app_flows_test.dart` (shared
  spawn + ping in `setUpAll`, fresh container per test, connect/disconnect
  per test, temp dirs cleaned in `finally`).

## 6. Feedback: toasts only

* `toastStoreProvider` + `ToastOverlay` is the single user-feedback
  system. `ScaffoldMessenger`/`SnackBar` must not be used in new code;
  all 10 legacy sites were migrated in System 6.
* Severities: success (confirmations), warning (no-result searches),
  error (failures), info (neutral notes + undo).
* Undo flows: `push(message, actionLabel: 'Undo', onAction: ...)` —
  the card runs the callback then dismisses. Pinned by
  `toast_overlay_test.dart` (action button test).

## 7. Recording I/O: one door

* `RecordingRepository` (`loadReplay`, `decodePreview`, trim via
  `flight_trim.dart`) is the only entry UI/state may use. Never import
  `FileParser` / `readRecordingChunks` / `decodeRecordingFrames`
  outside `services/`.

## 8. Known exceptions (do not "fix" without a task)

* `DeadReckoningTuneController` stays sync-`Notifier`: the estimator
  needs defaults before async prefs load. Uses compact-or-JSON parse.
* `core/packet_rate_tracker.dart` + `core/channel_health.dart`
  `ChannelHealthTracker` stay for their unit tests; no widget may use
  them — widgets read `channelHealthProvider.series`.
* `TimeSeriesChart.decimateExtremes` keeps its local bucket loop until
  the `ListTimeSeries` adapter lands; new code uses
  `foundation/time/decimate.dart`.
* `ToastStore` ids are per-launch ints (ephemeral, dismiss identity);
  persisted entity ids use `Ids.next(prefix)`.
* `snackBarTheme` in `app_theme.dart` is dead config (no ScaffoldMessenger
  uses remain); remove it with the next theme pass.

## 9. Backlog (ordered)

1. Trail/map/thumbnail decimation onto `decimate(mode: strideStable)`.
2. `WorkspaceStore.promoteToDefaults` codegen out of prod store into
   `tool/` (debug-only, `dart:io` search does not belong in state).
3. `Colors.*` sweep outside `theme/` (map/satellite attribution,
   `workspace_grid` overlays, QR white) + drop `snackBarTheme`.
4. Two-click confirm (`control_panel`, `fsm`) into one `TwoClickButton`.
5. Narrow `select()` watches for chart/3D/FSM tiles (map tile is the model).
6. `HANDOFF.md` stale §6.7 (Monitor deleted) + Part 4 tree vs
   `docs/agents/` — consolidate into `docs/architecture.md`.
