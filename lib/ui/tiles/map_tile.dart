import '../../foundation/time/time_series.dart';

import 'package:serial/serial.dart' show TelemetryFrame;

import '../../foundation/time/decimation.dart';

import 'package:flutter/gestures.dart' show PointerPanZoomUpdateEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/tool_button.dart';
import './shared/map_tiles.dart';
import './shared/tile_io.dart' show satelliteAttribution, streetAttribution;

/// Flight map: launch site, GPS track + live fix, dead-reckoning track + live
/// estimate. Tiles are fetched from Esri (internet required).
///
/// Performance notes (panning/zooming used to jank):
/// - The [FlutterMap] skeleton (tile layer + camera) lives in [_MapWidgetState],
///   which deliberately does NOT watch the telemetry store — telemetry ticks
///   (~12 Hz) therefore never rebuild the tile layer nor touch the camera.
///   Track/marker overlays are leaf [ConsumerWidget]s ([_TrackPolylines],
///   [_LiveMarkers]) that repaint on their own.
/// - Follow moves are driven by a [ref.listen] subscription (no rebuild) and
///   a manual drag drops follow mode, so the camera never fights the user's
///   pan on the next telemetry tick.
/// - The GPS track is stride-decimated ([gpsTrackPoints]) — a full 9000-frame
///   ring would otherwise force flutter_map to re-project 9000 points on
///   every pan/zoom frame.
/// - Tile layers render instantaneously (no per-tile fade-in animation).
class MapTile extends ConsumerStatefulWidget {
  const MapTile({super.key});

  @override
  ConsumerState<MapTile> createState() => _MapWidgetState();
}

class _MapWidgetState extends ConsumerState<MapTile> {
  final MapController _mapController = MapController();
  bool _follow = true;
  bool _satellite = true;
  bool _mapReady = false;
  double _zoom = 15;
  bool _followMoveScheduled = false;

  static final _streetTiles = buildStreetLayer();

  static final _satelliteTiles = buildSatelliteLayer();

  static const _interactionOptions = InteractionOptions(
    flags:
        InteractiveFlag.drag |
        InteractiveFlag.scrollWheelZoom |
        InteractiveFlag.pinchZoom,
  );

  void _onMapReady() {
    _mapReady = true;
  }

  /// Tracks the live zoom and drops follow mode on a manual drag (centre
  /// moved at constant zoom). Zoom gestures keep follow: [_zoom] is updated
  /// so the next follow tick re-centres at the new zoom instead of snapping
  /// back. Programmatic follow moves arrive with `hasGesture: false` and
  /// never clear the flag.
  void _onPositionChanged(MapCamera position, bool hasGesture) {
    final zoomChanged = (position.zoom - _zoom).abs() > 1e-9;
    _zoom = position.zoom;
    if (hasGesture && !zoomChanged && _follow) {
      setState(() => _follow = false);
    }
  }

  void _scheduleFollow(LatLng target) {
    if (_followMoveScheduled) return;
    _followMoveScheduled = true;
    final zoom = _zoom;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followMoveScheduled = false;
      // The user may have grabbed the map (clearing follow) between the
      // schedule and this frame — re-check before yanking the camera.
      if (!mounted || !_mapReady || !_follow) return;
      try {
        _mapController.move(target, zoom);
      } catch (_) {
        // Map tore down / not ready yet — the next tick retries.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final site = ref.watch(effectiveLaunchSiteProvider);

    // Follow without rebuilding: telemetry ticks schedule a post-frame camera
    // move but never rebuild this widget, so the tile layer and the user's
    // pan/zoom gesture stay untouched at 10+ Hz.
    //
    // Never touch the controller during build: before the first FlutterMap
    // frame `move` throws ("widget rendered at least once"). The first
    // position is already covered by `initialCenter` below; follow updates
    // run post-frame once the map reports ready and swallow the not-ready
    // race — the next telemetry tick retries.
    ref.listen(telemetryStoreProvider.select((s) => s.latest), (_, next) {
      if (!_follow || !_mapReady) return;
      if (next == null || !next.gpsHasFix) return;
      _scheduleFollow(LatLng(next.latitude, next.longitude));
    });

    // First-frame centre only, read without subscribing: a replay (or live
    // session) that already has a fix still opens on it, but later ticks
    // don't rebuild the map skeleton.
    final firstFix = ref.read(telemetryStoreProvider).latest;
    final initialCenter = (firstFix != null && firstFix.gpsHasFix)
        ? LatLng(firstFix.latitude, firstFix.longitude)
        : (site != null
              ? LatLng(site.latitude, site.longitude)
              : const LatLng(50.0755, 14.4378));

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Listener(
              // Trackpad swipe arrives as pointer pan/zoom events rather
              // than wheel scrolls (which flutter_map ignores), so without
              // this a two-finger swipe does nothing on the map.
              onPointerPanZoomUpdate: _trackpadZoom,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: initialCenter,
                  initialZoom: 15,
                  minZoom: 3,
                  maxZoom: 19,
                  // Tile gaps (zoom steps, layer toggle, offline misses)
                  // paint nothing, so the background shows through: match it
                  // to the active layer or every gap flashes white.
                  backgroundColor: _satellite
                      ? satelliteMapBackground
                      : streetMapBackground,
                  interactionOptions: _interactionOptions,
                  onMapReady: _onMapReady,
                  onPositionChanged: _onPositionChanged,
                ),
                children: [
                  _satellite ? _satelliteTiles : _streetTiles,
                  const _TrackPolylines(),
                  // Static site marker: hoisted out of the telemetry-driven
                  // overlays so its Tooltip isn't rebuilt at telemetry rate.
                  if (site != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(site.latitude, site.longitude),
                          width: 30,
                          height: 30,
                          child: Tooltip(
                            message: 'Launch site: ${site.name}',
                            child: Icon(
                              Icons.flag,
                              size: 22,
                              color: AppColors.pinkDeep,
                              shadows: const [
                                Shadow(
                                  color: AppColors.fixedWhite,
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  const _LiveMarkers(),
                ],
              ),
            ),
            // Controls: follow + satellite toggle.
            Positioned(
              right: 8,
              top: 8,
              child: Column(
                children: [
                  ToolFab(
                    icon: _follow
                        ? Icons.my_location
                        : Icons.location_searching,
                    tooltip: 'Follow rocket',
                    active: _follow,
                    onTap: () => setState(() => _follow = !_follow),
                  ),
                  const SizedBox(height: 6),
                  ToolFab(
                    icon: _satellite ? Icons.map_outlined : Icons.satellite_alt,
                    tooltip: 'Toggle satellite',
                    active: _satellite,
                    onTap: () => setState(() => _satellite = !_satellite),
                  ),
                ],
              ),
            ),
            // Attribution.
            Positioned(
              right: 4,
              bottom: 2,
              child: Text(
                _satellite ? satelliteAttribution : streetAttribution,
                style: TextStyle(
                  fontSize: 9,
                  color: AppColors.fixedBlack.withValues(alpha: 0.45),
                ),
              ),
            ),
            if (constraints.maxHeight >= 170 && constraints.maxWidth >= 220)
              const _Legend(),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  /// Trackpad two-finger swipe → zoom. Precision touchpads report swipes as
  /// pointer pan/zoom events rather than wheel scrolls, which flutter_map
  /// ignores — without this a swipe does nothing on the map. Mirrors the
  /// wheel path exactly (same velocity, same cursor anchoring).
  ///
  /// The pinch (scale) component is deliberately skipped: flutter_map's own
  /// pinch-zoom owns it, so handling scale here too would double-zoom every
  /// pinch.
  void _trackpadZoom(PointerPanZoomUpdateEvent event) {
    if (!_mapReady) return;
    if ((event.scale - 1.0).abs() >= 0.001) return;
    final dy = event.panDelta.dy;
    if (dy == 0) return;
    try {
      final camera = _mapController.camera;
      final newZoom =
          (camera.zoom - dy * _interactionOptions.scrollWheelVelocity).clamp(
            3.0,
            19.0,
          );
      _zoom = newZoom;
      _mapController.move(
        camera.focusedZoomCenter(event.localPosition, newZoom),
        newZoom,
      );
    } catch (_) {
      // Controller not ready / torn down mid-gesture — safe to drop.
    }
  }
}

/// GPS + dead-reckoning track overlay. Rebuilds on telemetry data changes
/// only (see the version selector); the tile layer above is a sibling, so
/// track repaints never disturb loaded tiles or the camera gesture.
class _TrackPolylines extends ConsumerWidget {
  const _TrackPolylines();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Narrow version: packet/error/replay transitions that don't change the
    // visible track (e.g. CRC-error-only ticks) skip the rebuild — and with
    // it the polyline re-projection cost during pan/zoom.
    ref.watch(
      telemetryStoreProvider.select(
        (s) => (s.packetCount, s.deadReckoning, s.replaying),
      ),
    );
    final state = ref.read(telemetryStoreProvider);
    final replaying = state.replaying;
    final gps = gpsTrackPoints(state);
    return PolylineLayer(
      polylines: [
        // Dead reckoning: one dashed segment per GPS gap, each rooted
        // at the last known fix — never a single line from the pad.
        if (!replaying)
          for (final segment in deadReckoningSegments(state))
            if (segment.length > 1)
              Polyline(
                points: segment,
                strokeWidth: 2.5,
                color: AppColors.seriesDeadReckoning.withValues(alpha: 0.75),
                pattern: StrokePattern.dashed(segments: [6, 5]),
              ),
        // GPS track.
        if (gps.length > 1)
          Polyline(
            points: gps,
            strokeWidth: 3,
            color: AppColors.seriesGpsTrack,
          ),
      ],
    );
  }
}

/// Live position markers (GPS fix + dead reckoning estimate). Same rebuild
/// [_TrackPolylines]; marker widgets are cheap and carry no tooltips.
class _LiveMarkers extends ConsumerWidget {
  const _LiveMarkers();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      telemetryStoreProvider.select(
        (s) => (s.packetCount, s.deadReckoning, s.replaying),
      ),
    );
    final state = ref.read(telemetryStoreProvider);
    final latest = state.latest;
    final gpsPoint = (latest != null && latest.gpsHasFix)
        ? LatLng(latest.latitude, latest.longitude)
        : null;
    // Dead reckoning is a live-only gap filler — never shown during replay.
    final deadReckoning = state.replaying ? null : state.deadReckoning;
    final deadReckoningPoint = deadReckoning == null
        ? null
        : LatLng(deadReckoning.latitude, deadReckoning.longitude);
    if (gpsPoint == null && deadReckoningPoint == null) {
      return const MarkerLayer(markers: []);
    }
    return MarkerLayer(
      markers: [
        if (deadReckoningPoint != null)
          Marker(
            point: deadReckoningPoint,
            width: 16,
            height: 16,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.seriesDeadReckoning,
                  width: 2.5,
                ),
              ),
            ),
          ),
        if (gpsPoint != null)
          Marker(
            point: gpsPoint,
            width: 16,
            height: 16,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.seriesGpsTrack,
                border: Border.all(color: AppColors.fixedWhite, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.fixedBlack.withValues(alpha: 0.3),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// GPS track points for [state], stride-decimated to at most [maxPoints].
///
/// The ring holds up to 9000 frames; projecting all of them on every
/// pan/zoom frame is what made the map jank on long flights. Stride sampling
/// keeps the track shape (endpoints always included) while bounding the
/// per-frame projection cost. Two cheap O(n) passes, no per-frame churn for
/// skipped points (no [LatLng] allocation for them).
List<LatLng> gpsTrackPoints(TelemetryState state, {int maxPoints = 1500}) {
  final fixes = state.history.where((f) => f.gpsHasFix).toList(growable: false);
  return [
    for (final frame in decimate<TelemetryFrame>(
      ListTimeSeries<TelemetryFrame>((f) => f.receivedAtMs, fixes),
      (f) => f.receivedAtMs,
      const [],
      maxPoints: maxPoints,
      mode: Decimation.strideStable,
    ))
      LatLng(frame.latitude, frame.longitude),
  ];
}

/// Dead reckoning track split into one segment per GPS gap. Points within a
/// gap arrive at 1 Hz, so a >3 s jump starts a new gap; each segment is
/// rooted at the last known GPS fix so the dashed line grows out of where
/// the fix was lost instead of trailing back to the pad (or bridging two
/// unrelated gaps with a straight line).
///
/// Single O(history + dead reckoning) pass: both buffers are chronological,
/// so one forward walk tracks the newest fix at or before each dead
/// reckoning point. (The previous implementation re-scanned the whole
/// history newest-first per segment — quadratic on gap-heavy flights, on
/// every telemetry tick.)
List<List<LatLng>> deadReckoningSegments(TelemetryState state) {
  final history = state.history;
  final deadReckoning = state.deadReckoningHistory;
  final segments = <List<LatLng>>[];
  if (deadReckoning.isEmpty) return segments;

  var h = 0;
  final hLen = history.length;
  LatLng? lastFix;
  List<LatLng>? current;
  var prevMs = -1;

  for (var i = 0; i < deadReckoning.length; i++) {
    final p = deadReckoning.oldest(i);
    while (h < hLen) {
      final f = history.oldest(h);
      if (f.receivedAtMs > p.atMs) break;
      if (f.gpsHasFix) lastFix = LatLng(f.latitude, f.longitude);
      h++;
    }
    if (prevMs >= 0 && p.atMs - prevMs > 3000) {
      if (current != null) segments.add(current);
      current = null;
    }
    // Anchor at segment start; a fix arriving mid-gap can't move it because
    // the segment is already open.
    final anchor = lastFix;
    current ??= anchor == null ? <LatLng>[] : <LatLng>[anchor];
    current.add(LatLng(p.latitude, p.longitude));
    prevMs = p.atMs;
  }
  if (current != null) segments.add(current);
  return [
    for (final s in segments)
      if (s.length > 1) s,
  ];
}

/// Track-key overlay. Only depends on the replay flag (which flips rarely),
// so it subscribes to that alone and never repaints on telemetry ticks.
class _Legend extends ConsumerWidget {
  const _Legend();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final replaying = ref.watch(
      telemetryStoreProvider.select((s) => s.replaying),
    );
    return Positioned(
      left: 8,
      bottom: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.card.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _LegendRow(
              color: AppColors.seriesGpsTrack,
              label: 'GPS',
              solid: true,
            ),
            if (!replaying) ...[
              const SizedBox(height: 3),
              _LegendRow(
                color: AppColors.seriesDeadReckoning,
                label: 'Dead reckoning',
                solid: false,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final Color color;
  final String label;
  final bool solid;

  const _LegendRow({
    required this.color,
    required this.label,
    required this.solid,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: solid ? color : null,
            border: solid
                ? null
                : Border(
                    top: BorderSide(
                      color: color,
                      width: 2,
                      strokeAlign: BorderSide.strokeAlignInside,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: AppText.microLabel.copyWith(
            fontSize: 8.5,
            letterSpacing: 1,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}
