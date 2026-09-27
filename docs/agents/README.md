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
