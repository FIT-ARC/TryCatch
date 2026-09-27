/// Application-wide behavioral constants.
///
/// Visual/layout tokens (radii, padding, typography) live in [AppDimens] and
/// [AppText] inside `theme/app_colors.dart`. This file covers everything else:
/// capacities, timeouts, window geometry and feature-specific tuning values
/// that would otherwise be scattered as magic literals across the codebase.
abstract final class AppConfig {
  // ── Telemetry store ──────────────────────────────────────────────────────────

  /// Ring-buffer capacity: ~15 minutes at 10 Hz.
  static const int telemetryHistoryCapacity = 9000;

  /// Dead reckoning kicks in only after GPS has been silent this long (ms).
  static const int deadReckoningStaleMs = 1000;

  /// Update interval for dead reckoning extrapolation and history recording
  /// (ms). Lower values yield a smoother, more responsive estimate during link
  /// loss or GPS gaps. 100 ms corresponds to 10 Hz (matching telemetry rate).
  static const int deadReckoningUpdateIntervalMs = 100;

  /// Minimum time between UI-visible state rebuilds from the telemetry store
  /// (ms). High-frequency replay paths push packets faster than 10 Hz; this
  /// throttle keeps tiles from rebuilding on every ingestion.
  static const int minNotifyIntervalMs = 80;

  // ── Replay ───────────────────────────────────────────────────────────────────

  /// Speed multiplier presets offered in the playback bar.
  static const List<double> replaySpeeds = [0.5, 1, 4, 20];

  /// Replay ticker interval (ms): how often the virtual clock advances and
  /// due packets are ingested.
  static const int replayTickMs = 50;

  // ── Tile networking ──────────────────────────────────────────────────────────

  /// HTTP connection timeout for tile fetches.
  static const Duration tileConnectionTimeout = Duration(seconds: 8);

  /// HTTP response timeout for tile fetches.
  static const Duration tileResponseTimeout = Duration(seconds: 10);

  /// How long fetched tiles are kept in the flutter_map disk cache.
  static const Duration tileCacheTtl = Duration(days: 30);

  /// User-Agent sent with every tile request.
  static const String tileUserAgent = 'dev.trycatch.groundstation';

  /// Maximum zoom level served by Esri (imagery and street).
  static const double tileMaxZoom = 19;
  static const int tileMaxNativeZoom = 19;

  // ── Layout tree ──────────────────────────────────────────────────────────────
  // Divider thickness lives in `state/layout_tree.dart` (`dividerWidth`).

  // ── Window ───────────────────────────────────────────────────────────────────

  /// Default window width on first launch (logical pixels).
  static const double windowInitialWidth = 1280;

  /// Default window height on first launch (logical pixels).
  static const double windowInitialHeight = 800;

  /// Minimum allowed window width (logical pixels).
  static const double windowMinWidth = 1024;

  /// Minimum allowed window height (logical pixels).
  static const double windowMinHeight = 600;

  // ── Top-bar chrome ───────────────────────────────────────────────────────────

  /// Width of the left and right side zones in the top bar. Both sides share
  /// this width so the centered controls stay on the true screen midpoint.
  static const double topBarSideWidth = 264;
}
