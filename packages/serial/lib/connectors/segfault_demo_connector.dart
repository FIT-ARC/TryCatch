/// SegFault Demo connector: minimal event firmware variant as a plug-n-play
/// connector.
///
/// Same 33-byte wire as the OG SegFault firmware (`0x5AA5` LE sync +
/// 31-byte LE payload, no CRC — `Telemetry packet format is unchanged`),
/// but a different FSM / uplink / capability profile:
///
/// - 2×2 state matrix (`DemoFsm.h`), all RAM, boots into `RealtimeLocked`:
///   0 `RealtimeLocked` (stowed, fast 400 ms), 1 `RealtimeDeployed`
///   (deployed, fast), 2 `PowersaverLocked` (stowed, slow 10 s),
///   3 `PowersaverDeployed` (deployed, slow).
/// - Uplink `47 43 cmd arg` (`RemoteControl.cpp`): `55 00` stow,
///   `AA 00` deploy (both keep the realtime/powersaver variant),
///   `52 00` realtime (`R`), `50 00` powersaver (`P`, both keep the
///   locked/deployed variant), `01 <0..3>` direct set-state. No
///   `67 67` baseline reset — that belongs to the full flight firmware.
/// - No launch/apogee detection, no autonomous chute, no WiFi, no flash:
///   [events] is empty.
/// - GPS module is not initialized (`AvionicsConfig::EnableGps = false`,
///   offsets stay zero): frames carry no fix flags and [capabilities]
///   exclude both GPS fields, so tiles render "not provided" instead of a
///   pinned base-station dot.
library;

import '../telemetry/rocket_commands.dart' show UplinkDescription;
import 'connector.dart';
import 'segfault_connector.dart'
    show
        SegfaultConnectorParser,
        SegfaultFraming,
        SegfaultPacketCodec,
        segfaultMagicC,
        segfaultMagicG;

/// The SegFault Demo connector: demo-firmware profile over OG framing.
class SegfaultDemoConnector extends TelemetryConnector {
  const SegfaultDemoConnector();

  @override
  String get id => 'segfault_demo';

  @override
  String get displayName => 'Demo v1';

  @override
  String get description => 'Connector for the demo version of the v1 rocket';

  @override
  ConnectorStreamParser createParser() =>
      SegfaultConnectorParser(assumeGpsFix: false);

  @override
  int get framingPayloadLength => SegfaultFraming.payloadLength;

  static const List<ConnectorFsmState> _states = [
    ConnectorFsmState(
      id: 0,
      label: 'Realtime Locked',
      colorArgb: 0xFF7F788D,
      hasNosecone: true,
      hasParachute: false,
      showsParachute: false,
    ),
    ConnectorFsmState(
      id: 1,
      label: 'Realtime Deployed',
      colorArgb: 0xFF0DA39A,
      hasNosecone: false,
      hasParachute: true,
      showsParachute: true,
    ),
    ConnectorFsmState(
      id: 2,
      label: 'Powersaver Locked',
      colorArgb: 0xFF5A5468,
      hasNosecone: true,
      hasParachute: false,
      showsParachute: false,
    ),
    ConnectorFsmState(
      id: 3,
      label: 'Powersaver Deployed',
      colorArgb: 0xFF146B66,
      hasNosecone: false,
      hasParachute: true,
      showsParachute: true,
    ),
    ConnectorFsmState(
      id: 255,
      label: 'Unknown',
      colorArgb: 0xFFA29CA9,
      hasNosecone: false,
      hasParachute: false,
      showsParachute: false,
      pipeline: false,
    ),
  ];

  @override
  List<ConnectorFsmState> get states => _states;

  @override
  ConnectorFsmState stateForId(int id) {
    for (final s in _states) {
      if (s.id == id) return s;
    }
    return _states.last;
  }

  /// Command byte for the "set FSM state" uplink (`47 43 01 <id>`).
  static const int setStateCmd = 0x01;

  /// Stow uplink third byte (`55`).
  static const int stowCmd = 0x55;

  /// Deploy uplink third byte (`AA`).
  static const int deployCmd = 0xAA;

  /// Realtime uplink third byte (`R`).
  static const int realtimeCmd = 0x52;

  /// Powersaver uplink third byte (`P`).
  static const int powersaverCmd = 0x50;

  @override
  List<ConnectorCommand> get commands => const [
    ConnectorCommand(
      id: 'stow_parachute',
      label: 'Lock chute',
      description: 'Lock the parachute servo',
      bytes: [segfaultMagicG, segfaultMagicC, 0x55, 0x00],
    ),
    ConnectorCommand(
      id: 'deploy_parachute',
      label: 'Deploy chute',
      description: 'Deploy the parachute servo',
      bytes: [segfaultMagicG, segfaultMagicC, 0xAA, 0x00],
      danger: true,
    ),
    ConnectorCommand(
      id: 'realtime',
      label: 'Realtime',
      description: 'Fast telemetry (400 ms)',
      bytes: [segfaultMagicG, segfaultMagicC, 0x52, 0x00],
    ),
    ConnectorCommand(
      id: 'powersaver',
      label: 'Powersaver',
      description: 'Slow telemetry (10 s)',
      bytes: [segfaultMagicG, segfaultMagicC, 0x50, 0x00],
    ),
  ];

  static bool _isKnownStateId(int id) => id >= 0 && id <= 3;

  @override
  List<int>? bytesForState(int stateId) {
    if (!_isKnownStateId(stateId)) return null;
    return [segfaultMagicG, segfaultMagicC, setStateCmd, stateId];
  }

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
    if (bytes.length == 4 &&
        bytes[0] == segfaultMagicG &&
        bytes[1] == segfaultMagicC &&
        bytes[2] == setStateCmd &&
        _isKnownStateId(bytes[3])) {
      final state = stateForId(bytes[3]);
      return UplinkDescription(
        label: 'Set ${state.label}',
        subtitle: 'Flight-computer state request → ${state.label}',
      );
    }
    final hex = [
      for (final b in bytes.take(4)) b.toRadixString(16).padLeft(2, '0'),
    ].join(' ');
    return UplinkDescription(
      label: 'Unknown command',
      subtitle: 'Unrecognized uplink frame ($hex)',
    );
  }

  /// Demo firmware has no launch/apogee detection and no autonomous
  /// chute deployment, so there are no flight milestones.
  @override
  List<ConnectorEventDef> get events => const [];

  /// Everything except GPS and horizontal velocity: the GPS module is not
  /// initialized and its offset fields stay zero. Baro altitude, vertical
  /// velocity, IMU, attitude (accel-derived), battery, hall and FSM are
  /// populated exactly like the OG firmware.
  @override
  FieldCapabilities get capabilities => const FieldCapabilities({
    TelemetryField.baroAltitude,
    TelemetryField.velocityVertical,
    TelemetryField.acceleration,
    TelemetryField.gyro,
    TelemetryField.attitude,
    TelemetryField.battery,
    TelemetryField.hall,
    TelemetryField.fsm,
  });

  /// Base position the demo firmware reports with zero GPS offsets.
  /// Re-exported for tests/consumers that need the "pinned" coordinate.
  static double get baseLatitudeDeg => SegfaultPacketCodec.baseLatitudeDeg;

  /// See [baseLatitudeDeg].
  static double get baseLongitudeDeg => SegfaultPacketCodec.baseLongitudeDeg;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
