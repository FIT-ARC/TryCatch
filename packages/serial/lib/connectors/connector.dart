/// Plug-n-play telemetry connector interface.
///
/// A connector owns one rocket link format end to end: framing a raw
/// bytestream into the shared internal [TelemetryFrame], the FSM states the
/// rocket reports, the uplink commands it accepts, the flight events derived
/// from its state transitions, and which internal fields it actually
/// populates (so the UI can tell "no data yet" apart from "this connector
/// never provides this").
///
/// Raw bytes never leave the `serial` package: the worker parses with the
/// selected connector and only decoded [TelemetryFrame]s reach the UI.
/// Concrete connectors live next to this file (see `mock_connector.dart`);
/// every available connector is listed in `registry.dart`.
library;

import 'dart:typed_data';

import '../telemetry/rocket_commands.dart' show UplinkDescription;
import '../telemetry/telemetry_frame.dart';

/// One internal telemetry field a connector may or may not populate.
///
/// The internal [TelemetryFrame] always carries every field, but a
/// connector whose rocket never sends e.g. GPS leaves them at defaults —
/// tiles use [FieldCapabilities] to render "not provided by this connector"
/// instead of an eternal "waiting for data".
enum TelemetryField {
  /// WGS84 latitude/longitude + fix flags.
  gpsPosition,

  /// GPS altitude (MSL).
  gpsAltitude,

  /// Barometric altitude (AGL).
  baroAltitude,

  /// NED velocity triple.
  velocity,

  /// Body-frame acceleration triple.
  acceleration,

  /// Body-frame gyro triple.
  gyro,

  /// Heading/roll/pitch/yaw attitude.
  attitude,

  /// Battery voltage.
  battery,

  /// Hall breakaway sensor.
  hall,

  /// FSM state id.
  fsm,
}

/// Which internal fields a connector populates.
class FieldCapabilities {
  /// Fields this connector fills from the wire.
  final Set<TelemetryField> fields;

  const FieldCapabilities(this.fields);

  /// A connector that populates the whole internal frame.
  static const FieldCapabilities all = FieldCapabilities({
    TelemetryField.gpsPosition,
    TelemetryField.gpsAltitude,
    TelemetryField.baroAltitude,
    TelemetryField.velocity,
    TelemetryField.acceleration,
    TelemetryField.gyro,
    TelemetryField.attitude,
    TelemetryField.battery,
    TelemetryField.hall,
    TelemetryField.fsm,
  });

  /// Whether [field] carries live values on this connector.
  bool supports(TelemetryField field) => fields.contains(field);
}

/// One FSM state reported by a connector's rocket.
///
/// The internal frame carries the raw `fsmStateId` int; connectors give it
/// meaning: display label, tile color (ARGB, e.g. `0xFFD42A2A` — the serial
/// package is pure Dart and cannot depend on Flutter's `Color`), airframe
/// configuration flags, and whether the state belongs to the nominal flight
/// pipeline (progress bar + pipeline grid) or is an off-pipeline branch
/// (bench/debug states render in their own row with an empty bar).
class ConnectorFsmState {
  /// Wire value carried in the frame's FSM byte.
  final int id;

  /// Human-friendly name for UI display.
  final String label;

  /// Tile/accent color for this state, ARGB.
  final int colorArgb;

  /// Whether the nosecone is on in this state.
  final bool hasNosecone;

  /// Whether the parachute is deployed (open canopy or collapsed after
  /// touchdown).
  final bool hasParachute;

  /// Whether 3D views render the open canopy (only under an open chute).
  final bool showsParachute;

  /// Whether this state is part of the nominal flight pipeline.
  final bool pipeline;

  /// Whether the vehicle is verifiably on the pad/ground in this state
  /// (pre-launch idle/armed, landed). 3D views pin the rocket to pad
  /// height here instead of rendering baro drift as levitation.
  final bool grounded;

  const ConnectorFsmState({
    required this.id,
    required this.label,
    required this.colorArgb,
    required this.hasNosecone,
    required this.hasParachute,
    required this.showsParachute,
    this.pipeline = true,
    this.grounded = false,
  });
}

/// One uplink command a connector's rocket accepts.
class ConnectorCommand {
  /// Stable id for UI icons/keys (e.g. `'arm'`).
  final String id;

  /// Short button label.
  final String label;

  /// One-line description for tooltips and logs.
  final String description;

  /// Exact wire bytes to transmit.
  final List<int> bytes;

  /// Destructive commands get red accents + stronger confirmation.
  final bool danger;

  const ConnectorCommand({
    required this.id,
    required this.label,
    required this.description,
    required this.bytes,
    this.danger = false,
  });
}

/// One state transition that can fire an event.
class ConnectorTransition {
  final int fromStateId;
  final int toStateId;

  const ConnectorTransition(this.fromStateId, this.toStateId);
}

/// One flight milestone derived from a connector's state transitions.
///
/// Most milestones are one transition ([fromStateId] → [toStateId]);
/// firmware that skips states lists the extra jumps in
/// [additionalTransitions] (e.g. apogee fires on ascent→apogee where
/// reported, or on the direct ascent→parachute jump where no apogee
/// state exists).
class ConnectorEventDef {
  /// Short human-readable name (e.g. `'Launch'`).
  final String label;

  /// State id before the transition.
  final int fromStateId;

  /// State id after the transition.
  final int toStateId;

  final List<ConnectorTransition> additionalTransitions;

  const ConnectorEventDef({
    required this.label,
    required this.fromStateId,
    required this.toStateId,
    this.additionalTransitions = const [],
  });

  /// Every transition that fires this event, primary first.
  Iterable<ConnectorTransition> get transitions sync* {
    yield ConnectorTransition(fromStateId, toStateId);
    yield* additionalTransitions;
  }

  bool matches(int fromStateId, int toStateId) => transitions.any((t) =>
      t.fromStateId == fromStateId && t.toStateId == toStateId);

  /// Human-readable subtitle for the transition that actually fired, e.g.
  /// `Armed → Ascent`.
  String transitionLabel(
          String Function(int id) labelFor, int fromStateId, int toStateId) =>
      '${labelFor(fromStateId)} → ${labelFor(toStateId)}';
}

/// Stateful bytestream → internal-frame parser owned by a connector.
///
/// One session per live connection / file decode: feed raw chunks, get back
/// decoded [TelemetryFrame]s. Counter getters feed channel health; the UI
/// never sees the raw bytes.
abstract class ConnectorStreamParser {
  /// Feeds a raw byte chunk, returning every complete frame it completes.
  ///
  /// Pass [timestampMs] when replaying recorded streams to preserve the
  /// original arrival times; defaults to wall-clock for live streaming.
  List<TelemetryFrame> feed(Uint8List chunk, {int? timestampMs});

  /// Clears the accumulation buffer (keeps counters).
  void reset();

  /// Clears the buffer and all cumulative byte counters.
  void resetStats();

  /// Every raw byte ever fed (including garbage and corrupt frames).
  int get totalBytes;

  /// Valid frames decoded so far.
  int get matchedPackets;

  /// Bytes consumed as valid packets (framing + payload each).
  int get matchedBytes;

  /// Bytes discarded while hunting for sync (unknown traffic/noise).
  int get garbageBytes;

  /// Frames dropped on integrity-check mismatch.
  int get crcErrorCount;

  /// Bytes consumed by integrity-failed frames.
  int get crcErrorBytes;
}

/// Plug-n-play telemetry connector: one rocket link format.
///
/// Implementations provide framing + state/command/event vocabularies +
/// capabilities; the shared [TelemetryFrame] is the only thing that leaves
/// the package.
abstract class TelemetryConnector {
  const TelemetryConnector();

  /// Stable id stamped into recording headers (e.g. `'mock'`).
  String get id;

  /// Short display name for the settings toggle + recording badges.
  String get displayName;

  /// One-line description for the settings toggle.
  String get description;

  /// Creates a fresh stateful stream parser for one session.
  ConnectorStreamParser createParser();

  /// Wire payload length stamped into recording headers, so readers know
  /// the framing the body was written with (52 mock, 31 segfault family).
  int get framingPayloadLength;

  /// Every FSM state this rocket can report, in display order.
  ///
  /// Includes the unknown fallback ([unknownStateId]) so [stateForId] can
  /// always resolve; surfaces that offer states for interaction (e.g. the
  /// FSM tile chips) hide it via [unknownStateId].
  List<ConnectorFsmState> get states;

  /// Descriptor for a wire state id, or the unknown fallback.
  ConnectorFsmState stateForId(int id);

  /// Wire id of the unknown fallback state.
  ///
  /// The FSM tile hides this from the request chips (it can never be
  /// requested) but still renders it as the big readout when the rocket
  /// actually reports it.
  int get unknownStateId => 255;

  /// Uplink command catalog (control panel).
  List<ConnectorCommand> get commands;

  /// Wire bytes requesting FSM state [stateId], if the rocket supports it
  /// (`null` when state requests are unavailable on this connector).
  List<int>? bytesForState(int stateId);

  /// Human-readable description of raw uplink bytes (command log tiles),
  /// resolved against this connector's catalog at display time.
  UplinkDescription describeCommand(List<int> bytes);

  /// Flight milestones derived from this connector's state transitions.
  List<ConnectorEventDef> get events;

  /// Which internal fields this connector populates.
  FieldCapabilities get capabilities;
}
