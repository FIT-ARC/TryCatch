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
  final double maxAlt;
  final double maxHoriz;
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
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.showNoseCone,
    required this.showParachute,
    required this.siteName,
  });

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

/// Caps a chronological point list to about [maxPoints], striding from the
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
    if (!f.gpsHasFix) continue;
    final bucket = f.receivedAtMs ~/ flightTrailBucketMs;
    if (bucket == lastGpsBucket) continue;
    all.add(enu(f.latitude, f.longitude, f.baroAltitude));
    lastGpsBucket = bucket;
  }
  final trail = capTrailPoints(all);

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
/// position share one centered moving average with full lookahead — exactly
/// like the legacy web visualizer — and the rocket always sits on the trail
/// tip instead of teleporting ahead of a lagging line. Raw frames are
/// smoothed first and decimated after: decimating first aliases the GPS
/// quantization grid (1e-5 deg ≈ 1.1 m) into visible wiggles no post-hoc
/// average can remove. Altitude stays raw in both modes; the recorded
/// frames, charts and map are unaffected (always raw).
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

  // Fix-only subsequence (matches the live builder: the trail is GPS).
  final fixIdx = <int>[];
  for (var i = 0; i < frames.length; i++) {
    if (frames[i].gpsHasFix) fixIdx.add(i);
  }
  // Tip: last fix at or before the playhead.
  lo = 0;
  hi = fixIdx.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (fixIdx[mid] <= idx) {
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
      pitchDeg: padAttitude.pitchDeg,
      yawDeg: padAttitude.yawDeg,
      rollDeg: padAttitude.rollDeg,
      showNoseCone: c.stateForId(tipFrame.fsmStateId).hasNosecone,
      showParachute: c.stateForId(tipFrame.fsmStateId).showsParachute,
      siteName: site?.name,
    );
  }

  Vector3 rawAt(int k) => worldOf(frames[fixIdx[k]]);

  Vector3 smoothAt(int k) {
    // Centered ±35 over the fix subsequence, clamped to the FULL recording
    // (lookahead into not-yet-played frames — the legacy visualizer smoothed
    // its whole dataset the same way). Horizontal only; altitude stays raw.
    var a = k - replayTrailHalfWindow;
    var b = k + replayTrailHalfWindow;
    if (a < 0) a = 0;
    if (b > fixIdx.length - 1) b = fixIdx.length - 1;
    var sx = 0.0;
    var sz = 0.0;
    for (var j = a; j <= b; j++) {
      final p = rawAt(j);
      sx += p.x;
      sz += p.z;
    }
    final n = b - a + 1;
    return Vector3(sx / n, rawAt(k).y, sz / n);
  }

  // Decimate to a paintable point count via capTrailPoints: tip-exact,
  // start-kept, and stable as the playhead advances (the old tip-derived
  // stride resampled earlier points on every seek step).
  final rawTrail = <Vector3>[];
  for (var k = 0; k <= tip; k++) {
    rawTrail.add(smoothingEnabled ? smoothAt(k) : rawAt(k));
  }
  final trail = capTrailPoints(rawTrail);
  final tipPoint = trail.last;

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
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    rollDeg: rollDeg,
    showNoseCone: c.stateForId(tipFrame.fsmStateId).hasNosecone,
    showParachute: c.stateForId(tipFrame.fsmStateId).showsParachute,
    siteName: site?.name,
  );
}

/// Live-vs-replay scene resolution shared by every 3D tile.
///
/// Replays render from the recording's full pre-decoded frames (whole flight
/// addressable, shared trail/rocket smoothing); live renders raw from the
/// bounded ring buffer. `null` when no position anchor exists yet.
FlightScene? resolveFlightScene({
  required TelemetryState state,
  required LaunchSite? site,
  required ReplayState replay,
  TelemetryConnector? connector,
}) {
  if (replay.isActive && replay.frames.isNotEmpty) {
    return buildReplayScene(
      frames: replay.frames,
      positionMs: replay.positionMs,
      site: site,
      smoothingEnabled: replay.smoothingEnabled,
      connector: connector,
    );
  }
  return buildFlightScene(state, site, connector: connector);
}

/// Display attitude shared by the orientation viewer: raw live angles, or
/// the trailing-average smoothed attitude while a smoothed replay runs, so
/// the airframe stops jittering when the toggle is on.
({double pitchDeg, double yawDeg, double rollDeg}) resolveDisplayAttitude({
  required double pitchDeg,
  required double yawDeg,
  required double rollDeg,
  required ReplayState replay,
}) {
  if (replay.isActive &&
      replay.frames.isNotEmpty &&
      replay.smoothingEnabled) {
    return replayAttitude(
      frames: replay.frames,
      positionMs: replay.positionMs,
      smoothingEnabled: true,
    );
  }
  return (pitchDeg: pitchDeg, yawDeg: yawDeg, rollDeg: rollDeg);
}

/// Half-width of the centered trail average ([buildReplayScene]) and the
/// length of the trailing rotation average ([replayAttitude]).
const int replayTrailHalfWindow = 35;
const int replayAttitudeWindow = 35;

/// Replay rotation at [positionMs]: raw frame angles by default, or the
/// smoothed display attitude when [smoothingEnabled].
///
/// The smoothed path matches [buildReplayScene]: a trailing
/// [replayAttitudeWindow]-frame averaged specific-force vector via
/// [smoothedAttitude] with yaw forced to 0 (compass heading is unknown —
/// the legacy yaw was always 0). Shared by the flight views (via
/// [buildReplayScene]) and the orientation viewer so the toggle smooths
/// every rotating airframe, not just the trail views.
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
  var from = idx - (replayAttitudeWindow - 1);
  if (from < 0) from = 0;
  final attitude = smoothedAttitude(frames.sublist(from, idx + 1),
      window: replayAttitudeWindow);
  return (
    pitchDeg: attitude.pitchDeg,
    yawDeg: 0.0,
    rollDeg: attitude.rollDeg,
  );
}

/// Display attitude from an averaged specific-force vector, using the same
/// tilt-from-accelerometer formula the legacy ground station applied per
/// packet. Averaging the vector (not the angles) keeps `atan2` stable when
/// the per-frame estimate swings — near free-fall at apogee, chute swing,
/// vibration — while still tracking real orientation changes. `frames` must
/// be chronological with the newest last; at most the trailing [window]
/// entries are used. Pure: safe to unit-test.
({double rollDeg, double pitchDeg}) smoothedAttitude(
  List<TelemetryFrame> frames, {
  int window = 25,
}) {
  if (frames.isEmpty) return (rollDeg: 0.0, pitchDeg: 0.0);
  final n = math.min(window, frames.length);
  var ax = 0.0;
  var ay = 0.0;
  var az = 0.0;
  for (var i = frames.length - n; i < frames.length; i++) {
    ax += frames[i].accelX;
    ay += frames[i].accelY;
    az += frames[i].accelZ;
  }
  ax /= n;
  ay /= n;
  az /= n;
  return (
    rollDeg: math.atan2(ay, az) * 180 / math.pi,
    pitchDeg: math.atan2(-ax, math.sqrt(ay * ay + az * az)) * 180 / math.pi,
  );
}
