// Shared human formatting helpers (durations as m:ss).
//
// Two "ago" vocabularies: log rows use whole seconds ([formatAgoMs],
// `12 s ago` / `3 m 04 s ago`); link-silence readouts keep sub-second
// precision ([formatPacketAge], `850 ms ago` / `3.2 s ago`).

/// Milliseconds → `m:ss` (e.g. 95000 → `1:35`).
String formatMinSec(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Chart x-axis seconds → `m:ss` (e.g. 95.0 → `1:35`).
///
/// Replay axes count up from launch, so negatives clamp to zero and the
/// value rounds to the nearest second. Live rolling windows keep their own
/// `-Ns` labels — use this only for whole-flight replay axes + tooltips.
String formatAxisMinSec(double seconds) {
  if (!seconds.isFinite) return '0:00';
  final ms = (seconds * 1000).round().clamp(0, 1 << 31);
  return formatMinSec(ms);
}

/// Clock-friendly x-axis step for whole-flight replay axes (~4-5 labels).
///
/// Snaps `totalSeconds / 5` up to the next step that lands on whole
/// minutes (5s, 10s, 15s, 30s, 1m, 2m, 3m, 5m, …) so `M:SS` ticks stay
/// round instead of landing on e.g. `3:30` or `8:20`.
double replayXInterval(double totalSeconds) {
  if (!totalSeconds.isFinite || totalSeconds <= 0) return 5;
  final target = totalSeconds / 5;
  const steps = [
    5.0,
    10.0,
    15.0,
    30.0,
    60.0,
    120.0,
    180.0,
    300.0,
    600.0,
    900.0,
    1800.0,
  ];
  for (final s in steps) {
    if (s >= target) return s;
  }
  return 3600;
}

/// Metres → `12 m` / `12.3 m` (no decimals past 100 m, `—` when null).
String formatAltitudeM(double? m) => m == null
    ? '—'
    : '${m.toStringAsFixed(m.abs() >= 100 ? 0 : 1)} m';

/// Metres → `850 m` / `1.24 km` (kilometres past 1000 m).
String formatDistanceM(double metres) => metres >= 1000
    ? '${(metres / 1000).toStringAsFixed(2)} km'
    : '${metres.toStringAsFixed(0)} m';

/// WGS84 pair with degree marks (`50.07550°, 14.43780°`).
String formatLatLon(double lat, double lon) =>
    '${lat.toStringAsFixed(5)}°, ${lon.toStringAsFixed(5)}°';

/// Plain paste format — Google Maps search takes it as-is.
String formatLatLonPlain(double lat, double lon) =>
    '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';

/// Date → `2026-09-09 14:03` (local).
String formatDateTime(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')} '
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}';

/// Duration since the last packet → `850 ms ago` / `3.2 s ago` / `2m 5s ago`.
String formatPacketAge(Duration d) {
  final s = d.inMilliseconds / 1000.0;
  if (s < 1.0) return '${d.inMilliseconds} ms ago';
  if (s < 60) return '${s.toStringAsFixed(1)} s ago';
  return '${d.inMinutes}m ${d.inSeconds % 60}s ago';
}

/// Duration → `45 s in state` / `3 m 07 s in state`.
String formatTimeInState(Duration d) {
  final seconds = d.inMilliseconds / 1000;
  final m = seconds ~/ 60;
  final s = (seconds % 60).toStringAsFixed(0).padLeft(2, '0');
  return '${m > 0 ? '$m m ' : ''}$s s in state';
}

/// Milliseconds → `5 s ago` / `3 m 04 s ago` (clamped at zero).
/// Log-row ages (events, commands); whole seconds, no ms branch.
String formatAgoMs(int ms) {
  final s = (ms.clamp(0, 1 << 62)) ~/ 1000;
  if (s < 60) return '$s s ago';
  return '${s ~/ 60} m ${(s % 60).toString().padLeft(2, '0')} s ago';
}
