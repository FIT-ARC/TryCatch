import 'dart:math' as math;

import 'package:serial/serial.dart';

/// Style vocabulary for the nominal flight milestones.
///
/// Each entry is a full definition: display [label], the matching state
/// change ([from] → [to]) and a `transitionLabel` subtitle. Detection
/// ([detectFlightEvents]) is driven by the active connector's event table
/// ([TelemetryConnector.events]) — one event per matching transition, in
/// frame order — so a recording may contain zero, one or several markers
/// of each type (e.g. bench tests re-arming, or a file trimmed to cruise
/// only). Events whose transition matches no entry here still surface with
/// [FlightEvent.label]/`transitionLabel` but no styled [FlightEvent.type].
enum FlightEventType {
  /// Liftoff.
  launch('Launch', FsmState.armed, FsmState.ascent),

  /// Nosecone popped at the top.
  apogee('Apogee', FsmState.ascent, FsmState.apogee),

  /// Canopy open.
  parachute('Parachute', FsmState.apogee, FsmState.parachute),

  /// Flight over.
  touchdown('Touchdown', FsmState.parachute, FsmState.landed);

  const FlightEventType(this.label, this.from, this.to);

  /// Short human-readable name for tooltips, logs and labels.
  final String label;

  /// FSM state before the transition.
  final FsmState from;

  /// FSM state after the transition.
  final FsmState to;

  /// Human-readable transition subtitle, e.g. `Armed → Ascent`.
  String get transitionLabel => '${from.label} → ${to.label}';
}

/// A single detected milestone inside a decoded flight.
class FlightEvent {
  /// Style-table entry for this marker, or `null` when the connector's
  /// transition matches no [FlightEventType] (render with the fallback
  /// style, [flightEventStyleOf] handles null).
  final FlightEventType? type;

  /// Short human-readable name (connector event label).
  final String label;

  /// Human-readable transition subtitle, e.g. `Armed → Ascent`.
  final String transitionLabel;

  /// Index of the first frame carrying the new state.
  final int frameIndex;

  /// Flight-clock position of that frame, relative to the first frame (ms).
  final int positionMs;

  /// Wall/flight timestamp of that frame ([TelemetryFrame.receivedAtMs]).
  /// Live logs derive "N s ago" from this; replay logs use [positionMs].
  final int receivedAtMs;

  const FlightEvent({
    required this.type,
    required this.label,
    required this.transitionLabel,
    required this.frameIndex,
    required this.positionMs,
    required this.receivedAtMs,
  });

  @override
  String toString() =>
      'FlightEvent($label @ frame $frameIndex, ${positionMs}ms)';
}

/// Maps a connector event definition to the style vocabulary by matching
/// the nominal state-id pair, or `null` for connector-specific events
/// outside the nominal profile.
FlightEventType? flightEventTypeForDef(ConnectorEventDef def) {
  for (final candidate in FlightEventType.values) {
    if (candidate.from.id == def.fromStateId &&
        candidate.to.id == def.toStateId) {
      return candidate;
    }
  }
  return null;
}

/// Scans [frames] (chronological) for FSM transitions marking flight
/// milestones and returns one [FlightEvent] per match, in frame order.
///
/// Matching is driven by the connector's event table ([eventDefs],
/// defaulting to [connector]'s — defaulting in turn to the MOCK
/// connector): only the table's exact transitions count; anything else
/// (skipped states, debug states, repeats of the same state) is ignored.
/// Empty or single-frame inputs yield no events.
List<FlightEvent> detectFlightEvents(
  List<TelemetryFrame> frames, {
  List<ConnectorEventDef>? eventDefs,
  TelemetryConnector? connector,
}) {
  final events = <FlightEvent>[];
  if (frames.length < 2) return events;
  final resolvedConnector = connector ?? mockConnector;
  final defs = eventDefs ?? resolvedConnector.events;
  String labelFor(int id) => resolvedConnector.stateForId(id).label;
  final t0 = frames.first.receivedAtMs;
  for (var i = 1; i < frames.length; i++) {
    final prev = frames[i - 1].fsmStateId;
    final curr = frames[i].fsmStateId;
    if (prev == curr) continue;
    ConnectorEventDef? def;
    for (final candidate in defs) {
      if (candidate.fromStateId == prev && candidate.toStateId == curr) {
        def = candidate;
        break;
      }
    }
    if (def == null) continue;
    events.add(
      FlightEvent(
        type: flightEventTypeForDef(def),
        label: def.label,
        transitionLabel: def.transitionLabel(labelFor),
        frameIndex: i,
        positionMs: frames[i].receivedAtMs - t0,
        receivedAtMs: frames[i].receivedAtMs,
      ),
    );
  }
  return events;
}

/// Diameter of a timeline marker dot, in logical pixels.
/// Canonical values live in `AppDimens`; kept here so pure layout code
/// doesn't import Flutter theme.
const double flightEventDotDiameterPx = 16;

/// Vertical distance between adjacent marker lanes, in logical pixels.
/// Chosen larger than [flightEventDotDiameterPx] so dots in neighbouring
/// lanes never touch even at identical horizontal positions.
const double flightEventLanePitchPx = 18;

/// A flight event resolved to an on-timeline position: the exact horizontal
/// pixel of the event plus a vertical lane offset separating markers that
/// would otherwise paint on top of each other.
class PlacedFlightEvent {
  /// The detected milestone.
  final FlightEvent event;

  /// Exact horizontal pixel of the event on a timeline whose value mapping
  /// runs from [trackLeftPx] to `trackLeftPx + trackWidthPx`.
  final double xPx;

  /// Vertical offset from the track center, in logical pixels. Zero means
  /// the dot sits on the track; anything else is drawn with a tick back to
  /// ([xPx], track center) so the true position stays visible.
  final double dyPx;

  const PlacedFlightEvent({
    required this.event,
    required this.xPx,
    required this.dyPx,
  });
}

/// Lays out [events] (chronological) on a timeline, spreading markers that
/// would overlap into alternating lanes above/below the track.
///
/// Every marker keeps its exact horizontal pixel; only the vertical lane
/// changes. Assignment is greedy in time order (earliest event wins the
/// on-track lane), checking 2D dot distance against every already-placed
/// marker, so any two dots end up at least [dotDiameterPx] + 2 px apart
/// centre-to-centre. When more markers collide than [maxLanes] holds, the
/// extras share the last lane (vanishingly rare — a handful of transitions
/// within one dot width).
///
/// Degenerate inputs (no events, non-positive duration/width/track) yield
/// no placements.
List<PlacedFlightEvent> placeFlightEvents(
  List<FlightEvent> events,
  int durationMs, {
  required double widthPx,
  required double trackLeftPx,
  required double trackWidthPx,
  double dotDiameterPx = flightEventDotDiameterPx,
  double lanePitchPx = flightEventLanePitchPx,
  int maxLanes = 3,
}) {
  final placed = <PlacedFlightEvent>[];
  if (events.isEmpty ||
      durationMs <= 0 ||
      widthPx <= 0 ||
      trackWidthPx <= 0 ||
      maxLanes <= 0) {
    return placed;
  }
  // Lane offsets: on-track first, then below the track, then above —
  // overflow runs downward where the eye follows the timeline.
  final laneDys = <double>[0];
  for (var i = 1; i < maxLanes; i++) {
    laneDys.add((i.isOdd ? 1 : -1) * lanePitchPx * ((i + 1) ~/ 2));
  }
  final minDist = dotDiameterPx + 2;
  for (final event in events) {
    final fraction = (event.positionMs / durationMs).clamp(0.0, 1.0).toDouble();
    final x = trackLeftPx + fraction * trackWidthPx;
    double? chosen;
    for (final dy in laneDys) {
      var fits = true;
      for (final other in placed) {
        final dyGap = (dy - other.dyPx).abs();
        if (dyGap >= minDist) continue;
        final needDx = math.sqrt(minDist * minDist - dyGap * dyGap);
        if ((x - other.xPx).abs() < needDx) {
          fits = false;
          break;
        }
      }
      if (fits) {
        chosen = dy;
        break;
      }
    }
    placed.add(
      PlacedFlightEvent(event: event, xPx: x, dyPx: chosen ?? laneDys.last),
    );
  }
  return placed;
}
