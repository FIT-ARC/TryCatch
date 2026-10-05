/// Pure scene data types and builder functions shared by the 3D flight views.
///
/// Camera, rendering and widget code lives in [flight_3d_common.dart];
/// this file has no Flutter dependency beyond [debugPrint].
library;

import 'dart:math' as math;

import 'package:dead_reckoning/dead_reckoning.dart' show metresPerDegreeLat;
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:vector_math/vector_math_64.dart' hide Colors;
import 'package:serial/serial.dart';

import '../../../state/launch_site_store.dart';
import '../../../state/replay_controller.dart';
import '../../../state/telemetry_store.dart';
/// World frame (right-handed, so the standard view matrix never mirrors):
/// X east, Y up (AGL), Z **south** — because E×U=S. (A previous revision used
/// +Z north, a left-handed frame that rendered east/west flipped.)
///
/// The compass language is shared too: E amber, U green, N blue.

/// User-selectable camera behaviour of the 3D flight views. The onboard
/// strap-down lens is its own tile, not a mode here.
enum FlightCameraMode {
  chase('Chase rocket', Icons.center_focus_strong),
  orbit('Orbit field', Icons.threesixty),
  free('Free orbit', Icons.control_camera);

  final String label;
  final IconData icon;

  const FlightCameraMode(this.label, this.icon);
}

/// Parses a persisted camera-mode name ([FlightCameraMode.name]); `null`
/// for missing or unknown names so callers can fall back to their default.
FlightCameraMode? tryParseFlightCameraMode(String? name) {
  if (name == null) return null;
  for (final mode in FlightCameraMode.values) {
    if (mode.name == name) return mode;
  }
  return null;
}

/// Everything a flight painter needs, rebuilt on every telemetry tick.
class FlightScene {
  /// GPS trail (east/up/south metres, oldest first).
  final List<Vector3> trail;
  final Vector3 rocketPos;

  /// `true` when [rocketPos] is a dead-reckoning estimate (GPS stale).
  final bool rocketIsDeadReckoning;

  /// Played-flight extents: camera framing follows them, so the orbit views
  /// keep zooming out and lifting as the flight grows.
  final double maxAlt;
  final double maxHoriz;

  /// Ground-grid extents: the whole flight in replay (the grid holds its
  /// final size from the first frame), [maxAlt]/[maxHoriz] live.
  final double gridMaxAlt;
  final double gridMaxHoriz;
  final double pitchDeg;
  final double yawDeg;
  final double rollDeg;

  /// Airframe configuration from the FSM state: nosecone on / canopy open.
  final bool showNoseCone;
  final bool showParachute;
  final String? siteName;

  const FlightScene({
    required this.trail,
    required this.rocketPos,
    required this.rocketIsDeadReckoning,
    required this.maxAlt,
    required this.maxHoriz,
    double? gridMaxAlt,
    double? gridMaxHoriz,
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.showNoseCone,
    required this.showParachute,
    required this.siteName,
  })  : gridMaxAlt = gridMaxAlt ?? maxAlt,
        gridMaxHoriz = gridMaxHoriz ?? maxHoriz;

  /// Copy with a replaced display attitude (the onboard lens eases the
  /// attitude each tick; trail and extents pass through untouched).
  FlightScene withAttitude({
    required double pitchDeg,
    required double yawDeg,
    required double rollDeg,
  }) =>
      FlightScene(
        trail: trail,
        rocketPos: rocketPos,
        rocketIsDeadReckoning: rocketIsDeadReckoning,
        maxAlt: maxAlt,
        maxHoriz: maxHoriz,
        gridMaxAlt: gridMaxAlt,
        gridMaxHoriz: gridMaxHoriz,
        pitchDeg: pitchDeg,
        yawDeg: yawDeg,
        rollDeg: rollDeg,
        showNoseCone: showNoseCone,
        showParachute: showParachute,
        siteName: siteName,
      );
}

/// Pure lat/lon → world mapping (east/up/south metres around [lat0]/[lon0]).
/// Exposed for unit tests locking the handedness: east must be +X,
/// north must be −Z.
Vector3 worldFromLatLon(
  double lat,
  double lon,
  double agl,
  double lat0,
  double lon0,
  double cosLat0,
) =>
    Vector3(
      (lon - lon0) * metresPerDegreeLat * cosLat0,
      math.max(0.0, agl),
      -(lat - lat0) * metresPerDegreeLat,
    );

/// Position anchor of a scene (world origin + ground level).
class FlightAnchor {
  final double lat;
  final double lon;
  final double groundMsl;
  final double cosLat;

  FlightAnchor({required this.lat, required this.lon, required this.groundMsl})
      : cosLat = math.cos(radians(lat));
}

/// World origin for [state]: the configured launch site, else the first GPS
/// fix. `null` when neither exists yet. Shared by the scene builder and the
/// satellite imagery so both agree exactly.
FlightAnchor? flightAnchor(TelemetryState state, LaunchSite? site) {
  if (site != null) {
    return FlightAnchor(
      lat: site.latitude,
      lon: site.longitude,
      groundMsl: site.altitudeMsl,
    );
  }
  final history = state.history;
  for (var i = 0; i < history.length; i++) {
    final f = history.getChronological(i);
    if (f.gpsHasFix) {
      return FlightAnchor(
        lat: f.latitude,
        lon: f.longitude,
        groundMsl: 0,
      );
    }
  }
  return null;
}

/// Fixed trail time bucket (ms): GPS fixes decimate on absolute buckets so
/// sampled points never move as history grows. (A span-derived bucket
/// resampled the whole trail every tick and the line visibly crawled.)
const int flightTrailBucketMs = 100;

/// Maximum trail points per scene; longer trails stride from the end via
/// [capTrailPoints] so the tip stays exact.
const int flightTrailMaxPoints = 400;

/// Whether [f] carries a usable GPS fix: flagged AND finite coordinates.
/// A NaN joint poisons its neighbours' averaged strip tangents (streaking
/// the whole line), where independent quads contained it to one segment.
/// Pure.
bool hasFiniteFix(TelemetryFrame f) =>
    f.gpsHasFix &&
    f.latitude.isFinite &&
    f.longitude.isFinite &&
    f.baroAltitude.isFinite;

/// Indices surviving the collapse of consecutive near-identical points
/// (closer than [eps2] squared, 3D): zero-length spans carry no shape but
/// force arbitrary fallback tangents in joined strips, spiking where
/// independent quads rendered them invisibly. Pure.
List<int> collapseDuplicateRuns(List<Vector3> points,
    [double eps2 = 1e-6]) {
  final keep = <int>[];
  for (var k = 0; k < points.length; k++) {
    if (keep.isEmpty ||
        (points[k] - points[keep.last]).length2 > eps2) {
      keep.add(k);
    }
  }
  return keep;
}

/// Caps a chronological point list to about [maxPoints] with a start-anchored
/// power-of-two stride, so the tip is always exact and the start always kept.
/// Pure — unit-tested.
///
/// Growth stability is the point: appending points only appends to the output
/// — earlier samples never move. (Tip-anchored striding re-phased the whole
/// trail on every tick past the cap and the line visibly crawled as the
/// flight grew.) Doubling the stride — never +1 — means a stride change only
/// thins the kept set to a strict subset (plus the new tip), so even the
/// widely-spaced stride milestones don't shift surviving points.
List<Vector3> capTrailPoints(List<Vector3> points,
    {int maxPoints = flightTrailMaxPoints}) {
  if (points.length <= maxPoints) return points;
  final budget = math.max(2, maxPoints);
  var stride = 1;
  // Kept count is 2 (start + tip) plus every [stride]-th interior point.
  while (2 + (points.length - 2) ~/ stride > budget) {
    stride *= 2;
  }
  final out = <Vector3>[points[0]];
  for (var i = stride; i < points.length - 1; i += stride) {
    out.add(points[i]);
  }
  out.add(points.last);
  return out;
}

/// Builds the metric scene from the flight history: GPS trail, rocket
/// position, extents and readout. `null` when no position anchor exists yet
/// (frames arriving but no fix and no configured site).
///
/// This is the live path and always renders raw frames. Replays use
/// [buildReplayScene], which can smooth over the whole recording. Airframe
/// flags resolve with [connector] (defaults to the MOCK connector).
FlightScene? buildFlightScene(
  TelemetryState state,
  LaunchSite? site, {
  TelemetryConnector? connector,
}) {
  final history = state.history;
  if (history.isEmpty) return null;
  final latest = state.latest!;
  final c = connector ?? mockConnector;

  final anchor = flightAnchor(state, site);
  if (anchor == null) return null;
  final lat0 = anchor.lat;
  final lon0 = anchor.lon;
  final cosLat0 = anchor.cosLat;

  Vector3 enu(double lat, double lon, double agl) =>
      worldFromLatLon(lat, lon, agl, lat0, lon0, cosLat0);

  // Trail: GPS fixes only, decimated on FIXED absolute time buckets so
  // points never move as history grows, then capped from the end so the
  // tip stays exact. Dead reckoning is intentionally NOT part of the
  // trail — when GPS is stale the estimate is shown as a single violet
  // point (see showDeadReckoning). Raw relative altitude renders as-is.
  final all = <Vector3>[];
  var lastGpsBucket = -1;

  for (var i = 0; i < history.length; i++) {
    final f = history.getChronological(i);
    if (!hasFiniteFix(f)) continue;
    final bucket = f.receivedAtMs ~/ flightTrailBucketMs;
    if (bucket == lastGpsBucket) continue;
    all.add(enu(f.latitude, f.longitude, f.baroAltitude));
    lastGpsBucket = bucket;
  }
  final trail =
      capTrailPoints([for (final k in collapseDuplicateRuns(all)) all[k]]);

  // Current rocket position: GPS when available, dead reckoning otherwise.
  // Before the first fix (pad wait) the rocket sits on the pad — show it
  // there immediately instead of a blank "waiting" tile.
  // A silent link (no packets at all, e.g. disconnected radio) also falls
  // back to the dead reckoning estimate: the last frame still carries a
  // fix, so staleness is judged against the wall clock, exactly like the
  // store's extrapolator.
  final deadReckoningNow = state.replaying ? null : state.deadReckoning;
  final linkStale = deadReckoningNow != null &&
      !state.replaying &&
      DateTime.now().millisecondsSinceEpoch - latest.receivedAtMs >
          TelemetryStore.deadReckoningStaleMs;
  final showDeadReckoning =
      deadReckoningNow != null && (!latest.gpsHasFix || linkStale);
  Vector3 rocketPos;
  if (showDeadReckoning) {
    rocketPos = enu(deadReckoningNow.latitude, deadReckoningNow.longitude,
        deadReckoningNow.altitude);
  } else if (latest.gpsHasFix) {
    rocketPos = enu(latest.latitude, latest.longitude, latest.baroAltitude);
  } else if (trail.isNotEmpty) {
    rocketPos = trail.last;
  } else {
    rocketPos = enu(lat0, lon0, latest.baroAltitude);
  }

  var maxAlt = rocketPos.y;
  var maxHoriz =
      math.sqrt(rocketPos.x * rocketPos.x + rocketPos.z * rocketPos.z);
  for (final p in trail) {
    if (p.y > maxAlt) maxAlt = p.y;
    final h = math.sqrt(p.x * p.x + p.z * p.z);
    if (h > maxHoriz) maxHoriz = h;
  }

  return FlightScene(
    trail: trail,
    rocketPos: rocketPos,
    rocketIsDeadReckoning: showDeadReckoning,
    maxAlt: maxAlt,
    maxHoriz: maxHoriz,
    pitchDeg: latest.pitch,
    yawDeg: latest.yaw,
    rollDeg: latest.roll,
    showNoseCone: c.stateForId(latest.fsmStateId).hasNosecone,
    showParachute: c.stateForId(latest.fsmStateId).showsParachute,
    siteName: site?.name,
  );
}

/// Replay scene built from a recording's full pre-decoded frames.
///
/// Unlike [buildFlightScene] (bounded live ring, raw), the whole flight is
/// addressable here, so with [smoothingEnabled] the trail AND the rocket
/// position share one centered time average with full lookahead, and the
/// rocket always sits on the trail tip instead of teleporting ahead of a
/// lagging line. Raw frames are smoothed first and decimated after:
/// decimating first aliases the GPS quantization grid (1e-5 deg ≈ 1.1 m)
/// into visible wiggles no post-hoc average can remove. Altitude stays raw
/// in both modes; the recorded frames, charts and map are unaffected
/// (always raw).
FlightScene? buildReplayScene({
  required List<TelemetryFrame> frames,
  required int positionMs,
  required LaunchSite? site,
  bool smoothingEnabled = false,
  TelemetryConnector? connector,
}) {
  if (frames.isEmpty) return null;
  final c = connector ?? mockConnector;
  final t0 = frames.first.receivedAtMs;
  var lo = 0;
  var hi = frames.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (frames[mid].receivedAtMs - t0 <= positionMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  var idx = lo - 1;
  if (idx < 0) idx = 0;
  if (idx > frames.length - 1) idx = frames.length - 1;

  // Anchor: file site, else the first GPS fix in the recording.
  late final double lat0;
  late final double lon0;
  if (site != null) {
    lat0 = site.latitude;
    lon0 = site.longitude;
  } else {
    TelemetryFrame? fix;
    for (final f in frames) {
      if (f.gpsHasFix) {
        fix = f;
        break;
      }
    }
    if (fix == null) return null;
    lat0 = fix.latitude;
    lon0 = fix.longitude;
  }
  final cosLat0 = math.cos(radians(lat0));

  Vector3 worldOf(TelemetryFrame f) => worldFromLatLon(
        f.latitude,
        f.longitude,
        f.baroAltitude,
        lat0,
        lon0,
        cosLat0,
      );

  // Fix subsequence + world positions from the per-recording cache (one
  // O(n) build per recording, then O(log n) binary searches per display
  // frame instead of an O(n) rescan every tick).
  final pos = _replayPositions(frames, lat0, lon0, cosLat0, t0);
  // Grid extents cover the WHOLE recording (FlightScene.gridMax*): the
  // ground grid holds the full flight from the first frame while the camera
  // framing follows the played flight. Cached per decoded frame list.
  final (fullMaxAlt, fullMaxHoriz) = _replayFlightExtents(frames, worldOf);
  // Tip: last fix at or before the playhead (by flight-clock time, so a
  // vsync-extrapolated position between provider ticks still brackets the
  // right pair for interpolation).
  lo = 0;
  hi = pos.fixRelMs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (pos.fixRelMs[mid] <= positionMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final tip = lo - 1;
  final tipFrame = frames[idx];

  if (tip < 0) {
    // No fix yet: the rocket waits on the pad like in the live builder.
    final pad = worldFromLatLon(
        lat0, lon0, tipFrame.baroAltitude, lat0, lon0, cosLat0);
    final padAttitude = replayAttitude(
      frames: frames,
      positionMs: positionMs,
      smoothingEnabled: smoothingEnabled,
    );
    return FlightScene(
      trail: const [],
      rocketPos: pad,
      rocketIsDeadReckoning: false,
      maxAlt: pad.y,
      maxHoriz: 0,
      gridMaxAlt: fullMaxAlt,
      gridMaxHoriz: fullMaxHoriz,
      pitchDeg: padAttitude.pitchDeg,
      yawDeg: padAttitude.yawDeg,
      rollDeg: padAttitude.rollDeg,
      showNoseCone: c.stateForId(tipFrame.fsmStateId).hasNosecone,
      showParachute: c.stateForId(tipFrame.fsmStateId).showsParachute,
      siteName: site?.name,
    );
  }

  // Trail: GPS fixes only, capped to a paintable count (tip-exact,
  // start-kept, stable as the playhead advances). With smoothing the rocket
  // AND the trail tip share the despiked time average, and the tip is
  // spline-sampled between fixes by flight-clock fraction — at 10 Hz
  // telemetry the rocket would otherwise hold 100 ms then jump a full
  // step, visible even at that rate. The chase/onboard lenses ride on
  // `rocketPos`, so their cameras smooth with the same interpolation.
  final full = smoothingEnabled ? pos.smoothWorld : pos.rawWorld;
  final trail = _cappedPrefix(full, tip + 1);
  Vector3 tipPoint;
  if (smoothingEnabled &&
      tip >= 0 &&
      tip + 1 < pos.smoothWorld.length &&
      pos.fixRelMs[tip + 1] > pos.fixRelMs[tip] &&
      positionMs > pos.fixRelMs[tip]) {
    tipPoint = _splineTip(pos, tip, positionMs);
    if (trail.isNotEmpty) trail[trail.length - 1] = tipPoint;
  } else {
    tipPoint = trail.last;
  }

  // Camera framing follows the played flight; the grid holds the whole
  // recording's extents (see FlightScene.gridMax*).
  var maxAlt = tipPoint.y;
  var maxHoriz = math.sqrt(
      tipPoint.x * tipPoint.x + tipPoint.z * tipPoint.z);
  for (final p in trail) {
    if (p.y > maxAlt) maxAlt = p.y;
    final h = math.sqrt(p.x * p.x + p.z * p.z);
    if (h > maxHoriz) maxHoriz = h;
  }

  final attitude = replayAttitude(
    frames: frames,
    positionMs: positionMs,
    smoothingEnabled: smoothingEnabled,
  );
  final pitchDeg = attitude.pitchDeg;
  final yawDeg = attitude.yawDeg;
  final rollDeg = attitude.rollDeg;

  return FlightScene(
    trail: trail,
    // Same smoothing as the trail tip: the rocket can never disagree
    // with the line it sits on.
    rocketPos: tipPoint,
    rocketIsDeadReckoning: false,
    maxAlt: maxAlt,
    maxHoriz: maxHoriz,
    gridMaxAlt: fullMaxAlt,
    gridMaxHoriz: fullMaxHoriz,
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    rollDeg: rollDeg,
    showNoseCone: c.stateForId(tipFrame.fsmStateId).hasNosecone,
    showParachute: c.stateForId(tipFrame.fsmStateId).showsParachute,
    siteName: site?.name,
  );
}

/// Whole-flight extents per decoded recording, keyed by the frame list
/// (List identity ==). Recomputing them per played frame would sweep every
/// GPS fix each tick.
final Map<List<TelemetryFrame>, (double, double)> _replayExtentsCache = {};

/// Max altitude and horizontal distance over every GPS fix of [frames]
/// (world metres around the anchor). Pure besides the cache.
(double, double) _replayFlightExtents(
  List<TelemetryFrame> frames,
  Vector3 Function(TelemetryFrame) worldOf,
) {
  final cached = _replayExtentsCache[frames];
  if (cached != null) return cached;
  var maxAlt = 0.0;
  var maxHoriz = 0.0;
  for (final f in frames) {
    if (!f.gpsHasFix) continue;
    final p = worldOf(f);
    if (p.y > maxAlt) maxAlt = p.y;
    final h = math.sqrt(p.x * p.x + p.z * p.z);
    if (h > maxHoriz) maxHoriz = h;
  }
  final out = (maxAlt, maxHoriz);
  if (_replayExtentsCache.length > 4) _replayExtentsCache.clear();
  _replayExtentsCache[frames] = out;
  return out;
}

/// Live-vs-replay scene resolution shared by every 3D tile.
///
/// Replays render from the recording's full pre-decoded frames (whole flight
/// addressable, shared trail/rocket smoothing); live renders raw from the
/// bounded ring buffer. `null` when no position anchor exists yet.
/// [positionMsOverride] carries the vsync-extrapolated display clock (3D
/// tiles tick at the screen refresh rate while the provider ticks at 20 Hz);
/// charts and the store keep using the provider clock.
FlightScene? resolveFlightScene({
  required TelemetryState state,
  required LaunchSite? site,
  required ReplayState replay,
  TelemetryConnector? connector,
  int? positionMsOverride,
}) {
  if (replay.isActive && replay.frames.isNotEmpty) {
    return buildReplayScene(
      frames: replay.frames,
      positionMs: positionMsOverride ?? replay.positionMs,
      site: site,
      smoothingEnabled: replay.smoothingEnabled,
      connector: connector,
    );
  }
  return buildFlightScene(state, site, connector: connector);
}

/// Display attitude shared by the orientation viewer: raw live angles, or
/// the smoothed recorded attitude while a smoothed replay runs, so the
/// airframe stops jittering when the toggle is on.
({double pitchDeg, double yawDeg, double rollDeg}) resolveDisplayAttitude({
  required double pitchDeg,
  required double yawDeg,
  required double rollDeg,
  required ReplayState replay,
  int? positionMsOverride,
}) {
  if (replay.isActive &&
      replay.frames.isNotEmpty &&
      replay.smoothingEnabled) {
    return replayAttitude(
      frames: replay.frames,
      positionMs: positionMsOverride ?? replay.positionMs,
      smoothingEnabled: true,
    );
  }
  return (pitchDeg: pitchDeg, yawDeg: yawDeg, rollDeg: rollDeg);
}

/// Half-width (ms) of the centered trail average ([buildReplayScene]).
/// Time-based so the smoothing span is rate-independent: a fix-count window
/// smears whole minutes of a low-rate recording into corner-cutting mush
/// while barely covering a second at high rates.
const int replayTrailHalfMs = 1000;

/// Half-width (ms) of the centered attitude average ([replayAttitude]).
/// Short enough to track real dynamics (canopy swing, coning, heading
/// changes) while killing per-packet jitter.
const int replayAttitudeHalfMs = 500;

/// Per-recording GPS position cache for the replay scene builder.
///
/// `buildReplayScene` runs on every replay tick (and, with smoothing, on
/// every display vsync via the 3D tiles' ticker). Rescanning all frames per
/// build is O(N) per frame — a 26k-frame flight would sweep the whole log
/// 60×/s. The fix subsequence, its world positions and the centered
/// smoothed positions depend only on the frame list + anchor, so they are
/// built once per recording and reused. Per build is then two binary
/// searches plus a ≤400-point capped trail.
class _ReplayPosCache {
  final double lat0;
  final double lon0;
  final double cosLat0;
  final List<int> fixRelMs;
  final List<Vector3> rawWorld;
  final List<Vector3> smoothWorld;

  const _ReplayPosCache({
    required this.lat0,
    required this.lon0,
    required this.cosLat0,
    required this.fixRelMs,
    required this.rawWorld,
    required this.smoothWorld,
  });
}

final Map<List<TelemetryFrame>, _ReplayPosCache> _replayPosCache = {};

/// Cached fix subsequence + world positions for [frames] around
/// ([lat0], [lon0]). Rebuilt when the frame list identity or the anchor
/// changes; otherwise the retained lists are returned directly.
_ReplayPosCache _replayPositions(
  List<TelemetryFrame> frames,
  double lat0,
  double lon0,
  double cosLat0,
  int t0,
) {
  final cached = _replayPosCache[frames];
  if (cached != null && cached.lat0 == lat0 && cached.lon0 == lon0) {
    return cached;
  }
  final rawRelMs = <int>[];
  var rawWorld = <Vector3>[];
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    if (!hasFiniteFix(f)) continue;
    rawRelMs.add(f.receivedAtMs - t0);
    rawWorld.add(worldFromLatLon(
        f.latitude, f.longitude, f.baroAltitude, lat0, lon0, cosLat0));
  }
  // Collapse consecutive near-identical fixes alongside, keeping the three
  // lists aligned (see [collapseDuplicateRuns]).
  final keep = collapseDuplicateRuns(rawWorld);
  final fixRelMs = [for (final k in keep) rawRelMs[k]];
  rawWorld = [for (final k in keep) rawWorld[k]];
  // Despike: ±3-fix median on raw x/z first — a lone GPS glitch would
  // otherwise smear through the whole mean window. Median preserves real
  // steps and ramps; y stays raw.
  const medHalf = 3;
  final n = rawWorld.length;
  final medX = List<double>.filled(n, 0.0);
  final medZ = List<double>.filled(n, 0.0);
  final buf = List<double>.filled(2 * medHalf + 1, 0.0);
  for (var k = 0; k < n; k++) {
    for (var j = -medHalf; j <= medHalf; j++) {
      final m = (k + j).clamp(0, n - 1);
      buf[j + medHalf] = rawWorld[m].x;
    }
    buf.sort();
    medX[k] = buf[medHalf];
    for (var j = -medHalf; j <= medHalf; j++) {
      final m = (k + j).clamp(0, n - 1);
      buf[j + medHalf] = rawWorld[m].z;
    }
    buf.sort();
    medZ[k] = buf[medHalf];
  }
  // Centered time average with full-flight lookahead (the legacy visualizer
  // smoothed its whole dataset the same way). Horizontal only; altitude
  // stays raw. A sliding window over the sorted fix times keeps the build
  // O(n): the naive per-point scan is O(n × window).
  final smoothWorld = List<Vector3>.filled(n, Vector3.zero());
  var a = 0;
  var b = -1;
  var sumX = 0.0;
  var sumZ = 0.0;
  for (var k = 0; k < n; k++) {
    final center = fixRelMs[k];
    while (center - fixRelMs[a] > replayTrailHalfMs) {
      sumX -= medX[a];
      sumZ -= medZ[a];
      a++;
    }
    while (b + 1 < n && fixRelMs[b + 1] - center <= replayTrailHalfMs) {
      b++;
      sumX += medX[b];
      sumZ += medZ[b];
    }
    final count = b - a + 1;
    smoothWorld[k] = Vector3(
      sumX / count,
      rawWorld[k].y,
      sumZ / count,
    );
  }
  final out = _ReplayPosCache(
    lat0: lat0,
    lon0: lon0,
    cosLat0: cosLat0,
    fixRelMs: fixRelMs,
    rawWorld: rawWorld,
    smoothWorld: smoothWorld,
  );
  if (_replayPosCache.length > 4) _replayPosCache.clear();
  _replayPosCache[frames] = out;
  return out;
}

/// Capped prefix of [full] with [count] points, mirroring
/// `capTrailPoints(full.sublist(0, count))` without copying the full prefix:
/// start-kept, tip-exact, start-anchored power-of-two stride. Returns a new
/// list; [full] is never mutated.
List<Vector3> _cappedPrefix(List<Vector3> full, int count,
    {int maxPoints = flightTrailMaxPoints}) {
  if (count <= 0) return const [];
  if (count <= maxPoints) return List<Vector3>.of(full.sublist(0, count));
  final budget = math.max(2, maxPoints);
  var stride = 1;
  while (2 + (count - 2) ~/ stride > budget) {
    stride *= 2;
  }
  final out = <Vector3>[full[0]];
  for (var i = stride; i < count - 1; i += stride) {
    out.add(full[i]);
  }
  out.add(full[count - 1]);
  return out;
}

/// Time-parameterized Catmull-Rom sample of one scalar channel through
/// [p1]→[p2] at time [t] (knot times [t0]..[t3], Barry–Goldman form).
/// C1-continuous across knots: unlike linear interpolation, velocity never
/// steps at a fix, so low-rate curves stop ticking. Reproduces straight
/// constant-velocity runs exactly and hits both endpoints; degenerate
/// timestamp spans fall back to the nearer endpoint. Pure.
double _crSample(
  double p0,
  double p1,
  double p2,
  double p3,
  double t0,
  double t1,
  double t2,
  double t3,
  double t,
) {
  double seg(double a, double b, double ta, double tb) {
    final span = tb - ta;
    if (span.abs() < 1e-9) return t >= tb ? b : a;
    return a + (b - a) * ((t - ta) / span);
  }

  final a1 = seg(p0, p1, t0, t1);
  final a2 = seg(p1, p2, t1, t2);
  final a3 = seg(p2, p3, t2, t3);
  final b1 = seg(a1, a2, t0, t2);
  final b2 = seg(a2, a3, t1, t3);
  return seg(b1, b2, t1, t2);
}

/// Shortest-path unwrap of [angles] in sample order: each value shifted by
/// whole turns to sit nearest its predecessor, so cubic sampling never
/// slews the long way around the 0/360 wrap. Pure.
List<double> _unwrapAngles(List<double> angles) {
  final out = List<double>.filled(angles.length, 0.0);
  if (angles.isEmpty) return out;
  out[0] = angles[0];
  for (var i = 1; i < angles.length; i++) {
    var d = (angles[i] - out[i - 1]) % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    out[i] = out[i - 1] + d;
  }
  return out;
}

/// Spline tip sample at flight-clock [positionMs] between fixes [tip] and
/// [tip]+1: Catmull-Rom over x/z (velocity-continuous around curves),
/// linear over the raw baro altitude. The trail tip is replaced by this
/// value so the rocket always rides the line it draws. Pure.
Vector3 _splineTip(_ReplayPosCache pos, int tip, int positionMs) {
  final n = pos.smoothWorld.length;
  final i0 = math.max(0, tip - 1);
  final i3 = math.min(n - 1, tip + 2);
  final t = positionMs.toDouble();
  final t0 = pos.fixRelMs[i0].toDouble();
  final t1 = pos.fixRelMs[tip].toDouble();
  final t2 = pos.fixRelMs[tip + 1].toDouble();
  final t3 = pos.fixRelMs[i3].toDouble();
  final x = _crSample(
    pos.smoothWorld[i0].x,
    pos.smoothWorld[tip].x,
    pos.smoothWorld[tip + 1].x,
    pos.smoothWorld[i3].x,
    t0,
    t1,
    t2,
    t3,
    t,
  );
  final z = _crSample(
    pos.smoothWorld[i0].z,
    pos.smoothWorld[tip].z,
    pos.smoothWorld[tip + 1].z,
    pos.smoothWorld[i3].z,
    t0,
    t1,
    t2,
    t3,
    t,
  );
  final f = ((t - t1) / (t2 - t1)).clamp(0.0, 1.0);
  final y = pos.smoothWorld[tip].y +
      (pos.smoothWorld[tip + 1].y - pos.smoothWorld[tip].y) * f;
  return Vector3(x, y, z);
}

/// Replay rotation at [positionMs]: raw frame angles by default, or the
/// smoothed display attitude when [smoothingEnabled].
///
/// The smoothed path averages the RECORDED pitch/yaw/roll over a short
/// centered time window: the same motion the raw view shows, minus the
/// steps. Re-deriving tilt from accelerometers instead collapses real
/// dynamics (spin, canopy swing, heading) to vertical — averaging a
/// seconds-long swing over a multi-second window cancels it outright.
/// Shared by the flight views (via [buildReplayScene]) and the orientation
/// viewer so the toggle smooths every rotating airframe, not just the trail
/// views.
///
/// The window bracketing [positionMs] is spline-sampled by timestamp
/// fraction, so a 10 Hz recording rotates every display frame instead of
/// stepping once per packet.
({double pitchDeg, double yawDeg, double rollDeg}) replayAttitude({
  required List<TelemetryFrame> frames,
  required int positionMs,
  required bool smoothingEnabled,
}) {
  final t0 = frames.first.receivedAtMs;
  var lo = 0;
  var hi = frames.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (frames[mid].receivedAtMs - t0 <= positionMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  var idx = lo - 1;
  if (idx < 0) idx = 0;
  if (idx > frames.length - 1) idx = frames.length - 1;
  if (!smoothingEnabled) {
    final f = frames[idx];
    return (pitchDeg: f.pitch, yawDeg: f.yaw, rollDeg: f.roll);
  }

  /// Centered ±[replayAttitudeHalfMs] boxcar of one recorded channel around
  /// frame [at] (bounds by binary search — frames are chronological — then
  /// a plain mean over the small in-window run). Yaw/roll channels pass
  /// through circularly via sin/cos accumulation.
  ({double lin, double sinSum, double cosSum, int n}) channelAt(
      int at, double Function(TelemetryFrame) read) {
    final center = frames[at].receivedAtMs;
    var loB = 0;
    var hiB = frames.length;
    while (loB < hiB) {
      final mid = (loB + hiB) >> 1;
      if (frames[mid].receivedAtMs < center - replayAttitudeHalfMs) {
        loB = mid + 1;
      } else {
        hiB = mid;
      }
    }
    final from = loB;
    loB = 0;
    hiB = frames.length;
    while (loB < hiB) {
      final mid = (loB + hiB) >> 1;
      if (frames[mid].receivedAtMs <= center + replayAttitudeHalfMs) {
        loB = mid + 1;
      } else {
        hiB = mid;
      }
    }
    var lin = 0.0;
    var sinSum = 0.0;
    var cosSum = 0.0;
    var n = 0;
    for (var j = from; j < loB; j++) {
      final v = read(frames[j]);
      lin += v;
      final rad = v * math.pi / 180;
      sinSum += math.sin(rad);
      cosSum += math.cos(rad);
      n++;
    }
    return (lin: lin, sinSum: sinSum, cosSum: cosSum, n: n);
  }

  double pitchAt(int at) {
    final c = channelAt(at, (f) => f.pitch);
    return c.n == 0 ? frames[at].pitch : c.lin / c.n;
  }

  double circAt(int at, double Function(TelemetryFrame) read) {
    final c = channelAt(at, read);
    if (c.n == 0) return read(frames[at]);
    return math.atan2(c.sinSum, c.cosSum) * 180 / math.pi;
  }

  final last = frames.length - 1;
  final t = positionMs.toDouble();
  double rel(int i) => (frames[i].receivedAtMs - t0).toDouble();

  // Single centered value at the flight end (or when the bracket
  // collapses): nothing after it to spline toward.
  if (idx + 1 > last) {
    return (
      pitchDeg: pitchAt(idx),
      yawDeg: circAt(idx, (f) => f.yaw) % 360,
      rollDeg: circAt(idx, (f) => f.roll),
    );
  }
  final controls = [math.max(0, idx - 1), idx, idx + 1, math.min(last, idx + 2)];
  List<double> times() => [for (final i in controls) rel(i)];
  final ts = times();

  final pitch = _crSample(
    pitchAt(controls[0]),
    pitchAt(controls[1]),
    pitchAt(controls[2]),
    pitchAt(controls[3]),
    ts[0],
    ts[1],
    ts[2],
    ts[3],
    t,
  );
  final yawChain = _unwrapAngles(
      [for (final i in controls) circAt(i, (f) => f.yaw)]);
  final yaw = _crSample(
    yawChain[0],
    yawChain[1],
    yawChain[2],
    yawChain[3],
    ts[0],
    ts[1],
    ts[2],
    ts[3],
    t,
  ) % 360;
  final rollChain = _unwrapAngles(
      [for (final i in controls) circAt(i, (f) => f.roll)]);
  final roll = _crSample(
    rollChain[0],
    rollChain[1],
    rollChain[2],
    rollChain[3],
    ts[0],
    ts[1],
    ts[2],
    ts[3],
    t,
  );
  return (pitchDeg: pitch, yawDeg: yaw, rollDeg: roll);
}
