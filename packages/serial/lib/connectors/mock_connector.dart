/// MOCK connector: the original TryCatch wire format as a plug-n-play
/// connector.
///
/// Framing `0xAA55` + 52-byte payload (incl. trailing CRC16-CCITT), control
/// uplink `54 43 cmd arg`, FSM ids 0–7/255. This was the single hard-coded
/// format before connectors existed; every pre-connector recording decodes
/// with this connector (`id == 'mock'`).
library;

import 'dart:typed_data';

import '../constants.dart';
import '../io/packet_parser.dart';
import '../telemetry/frame_codec.dart';
import '../telemetry/rocket_commands.dart';
import '../telemetry/telemetry_frame.dart';
import 'connector.dart';

/// Stateful MOCK stream parser: sync-hunt + CRC-drop, then decode to the
/// shared internal frame.
class MockConnectorParser extends ConnectorStreamParser {
  final PacketParser _parser = PacketParser();

  @override
  List<TelemetryFrame> feed(Uint8List chunk, {int? timestampMs}) {
    final frames = <TelemetryFrame>[];
    for (final packet in _parser.feed(chunk, timestampMs: timestampMs)) {
      final frame = FrameCodec.decode(
        packet.rawData,
        receivedAtMs: packet.receivedAtMs,
      );
      if (frame != null) frames.add(frame);
    }
    return frames;
  }

  @override
  void reset() => _parser.reset();

  @override
  void resetStats() => _parser.resetStats();

  @override
  int get totalBytes => _parser.totalBytes;

  @override
  int get matchedPackets => _parser.matchedPackets;

  @override
  int get matchedBytes => _parser.matchedBytes;

  @override
  int get garbageBytes => _parser.garbageBytes;

  @override
  int get crcErrorCount => _parser.crcErrorCount;

  @override
  int get crcErrorBytes => _parser.crcErrorBytes;
}

/// The MOCK connector: original wire format, full internal frame.
class MockConnector extends TelemetryConnector {
  const MockConnector();

  @override
  String get id => 'mock';

  @override
  String get displayName => 'MOCK';

  @override
  String get description => 'Mock connector used with MOCK port for testing';

  @override
  ConnectorStreamParser createParser() => MockConnectorParser();

  @override
  int get framingPayloadLength => TelemetryFraming.payloadLength;

  /// ARGB tile colors per state (light-mode reference of the app `fsm*`
  /// palette — see `AppPalette`. The UI resolves the active light/dark
  /// variant via `AppColors.connectorStateColor`, so this stays a single
  /// set for the wire/recordings and must NOT be used directly
  /// for painting).
  static int _colorFor(FsmState state) => switch (state) {
    FsmState.idle => 0xFF7F788D,
    FsmState.armed => 0xFFE03434,
    FsmState.ascent => 0xFFF0B400,
    FsmState.apogee => 0xFFF07D12,
    FsmState.parachute => 0xFF0DA39A,
    FsmState.landed => 0xFF2A4A9B,
    FsmState.debugUnlocked => 0xFF6CA62E,
    FsmState.debugLocked => 0xFF8B44E8,
    FsmState.unknown => 0xFFA29CA9,
  };

  static ConnectorFsmState _describe(FsmState state) => ConnectorFsmState(
    id: state.id,
    label: state.label,
    colorArgb: _colorFor(state),
    hasNosecone: state.hasNosecone,
    hasParachute: state.hasParachute,
    showsParachute: state.showsParachute,
    pipeline:
        state != FsmState.debugUnlocked &&
        state != FsmState.debugLocked &&
        state != FsmState.unknown,
    grounded: state == FsmState.idle ||
        state == FsmState.armed ||
        state == FsmState.landed,
  );

  static const List<FsmState> _ordered = [
    FsmState.idle,
    FsmState.armed,
    FsmState.ascent,
    FsmState.apogee,
    FsmState.parachute,
    FsmState.landed,
    FsmState.debugUnlocked,
    FsmState.debugLocked,
    FsmState.unknown,
  ];

  @override
  List<ConnectorFsmState> get states => [
    for (final s in _ordered) _describe(s),
  ];

  @override
  ConnectorFsmState stateForId(int id) => _describe(FsmState.fromId(id));

  @override
  int get unknownStateId => FsmState.unknown.id;

  @override
  List<ConnectorCommand> get commands => [
    for (final cmd in RocketCommands.all)
      ConnectorCommand(
        id: cmd.id,
        label: cmd.label,
        description: cmd.description,
        bytes: cmd.bytes,
        danger: cmd.danger,
      ),
  ];

  @override
  List<int>? bytesForState(int stateId) {
    final state = FsmState.fromId(stateId);
    if (state == FsmState.unknown) return null;
    return FsmStateCommands.bytesFor(state);
  }

  @override
  UplinkDescription describeCommand(List<int> bytes) => describeUplink(bytes);

  @override
  List<ConnectorEventDef> get events => const [
        ConnectorEventDef(
          label: 'Launch',
          fromStateId: 1, // armed
          toStateId: 2, // ascent
        ),
        ConnectorEventDef(
          label: 'Apogee',
          fromStateId: 2, // ascent
          toStateId: 3, // apogee
          // Firmware without an apogee state jumps straight here.
          additionalTransitions: [ConnectorTransition(2, 4)],
        ),
        ConnectorEventDef(
          label: 'Parachute',
          fromStateId: 3, // apogee
          toStateId: 4, // parachute
        ),
        ConnectorEventDef(
          label: 'Touchdown',
          fromStateId: 4, // parachute
          toStateId: 5, // landed
        ),
      ];

  @override
  FieldCapabilities get capabilities => FieldCapabilities.all;
}
