/// Brno connector: static pad for downstream testing as a plug-n-play
/// connector.
///
/// Same 52-byte MOCK framing (`0xAA55` + payload with trailing CRC16) as
/// the MOCK connector, but a position-nudge profile: the FSM toggles
/// idle/parachute every 5 s and the uplink catalog moves the reported
/// position by 1 m per command (up / down shift baro altitude, east / west
/// shift longitude). There are no flight milestones and no FSM state
/// requests.
library;

import '../constants.dart';
import '../telemetry/rocket_commands.dart';
import '../telemetry/telemetry_frame.dart';
import 'connector.dart';
import 'mock_connector.dart';

/// The Brno connector: static pad with 1 m position-nudge commands.
class BrnoConnector extends TelemetryConnector {
  const BrnoConnector();

  @override
  String get id => 'brno';

  @override
  String get displayName => 'Brno';

  @override
  String get description =>
      'Static Brno pad with 1 m move commands for testing';

  @override
  ConnectorStreamParser createParser() => MockConnectorParser();

  @override
  int get framingPayloadLength => TelemetryFraming.payloadLength;

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
        pipeline: state != FsmState.debugUnlocked &&
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
  List<ConnectorCommand> get commands => const [
        ConnectorCommand(
          id: 'move_up',
          label: 'Up 1 m',
          description: 'Move reported position up by 1 metre',
          bytes: [rocketMagicT, rocketMagicC, 0x10, 0x00],
        ),
        ConnectorCommand(
          id: 'move_down',
          label: 'Down 1 m',
          description: 'Move reported position down by 1 metre',
          bytes: [rocketMagicT, rocketMagicC, 0x11, 0x00],
        ),
        ConnectorCommand(
          id: 'move_west',
          label: 'West 1 m',
          description: 'Move reported position west by 1 metre',
          bytes: [rocketMagicT, rocketMagicC, 0x13, 0x00],
        ),
        ConnectorCommand(
          id: 'move_east',
          label: 'East 1 m',
          description: 'Move reported position east by 1 metre',
          bytes: [rocketMagicT, rocketMagicC, 0x12, 0x00],
        ),
      ];

  /// Brno accepts no FSM state requests; position moves via [commands].
  @override
  List<int>? bytesForState(int stateId) => null;

  @override
  UplinkDescription describeCommand(List<int> bytes) {
    for (final cmd in commands) {
      if (_bytesEqual(cmd.bytes, bytes)) {
        return UplinkDescription(
          label: cmd.label,
          subtitle: cmd.description,
          danger: cmd.danger,
        );
      }
    }
    final hex = [
      for (final b in bytes.take(4)) b.toRadixString(16).padLeft(2, '0'),
    ].join(' ');
    return UplinkDescription(
      label: 'Unknown command',
      subtitle: 'Unrecognized uplink frame ($hex)',
    );
  }

  /// Static pad with no flight milestones.
  @override
  List<ConnectorEventDef> get events => const [];

  @override
  FieldCapabilities get capabilities => FieldCapabilities.all;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
