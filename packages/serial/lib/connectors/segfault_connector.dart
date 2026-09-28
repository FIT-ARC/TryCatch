/// SegFault connector: the OG rocket wire format as a plug-n-play connector.
///
/// Framing: 2-byte LE sync `0x5AA5` (wire bytes `A5 5A`) + 31-byte payload
/// = 33-byte packets, no CRC. Little-endian throughout (ESP32).
/// Uplink `47 43 cmd arg` ('GC'): deploy/stow servo, `01`+id set-state,
/// `67 67` reset baseline.
///
/// Field mapping (see `Telemetry.h` / `decodePacket.ts` in the OG repos):
/// - accel `raw * G / 2048` m/s², gyro `raw / 16.4` dps
/// - Kalman AGL `raw / 10` m → [TelemetryFrame.baroAltitude]
/// - GPS `base + raw * 1e-5` deg (bases below); the firmware sends no fix
///   flags and leaves offsets at 0 when invalid, so frames assume fix.
/// - vertical velocity `raw / 10` m/s up → `velocityDown = -up`
/// - battery `raw * 0.02` V, hall = KY-024 analog count
/// - roll/pitch derived from the accel vector (same gravity projection the
///   old web client used); yaw/heading stay 0 (underivable from accel).
/// - pressure / tribo have no internal field and are dropped.
///
/// The firmware has no integrity check, so framing is sync-hunt + fixed
/// length only: a `A5 5A` pair inside a payload will mis-frame, exactly as
/// the old server did. State ids 0–4; anything else maps to unknown (255).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../telemetry/rocket_commands.dart' show UplinkDescription;
import '../telemetry/telemetry_frame.dart';
import 'connector.dart';

/// Wire constants for the SegFault firmware (see `AvionicsConfig.h`).
abstract final class SegfaultFraming {
  /// First wire byte (LE low byte of 0x5AA5).
  static const int startByte0 = 0xA5;

  /// Second wire byte (LE high byte of 0x5AA5).
  static const int startByte1 = 0x5A;

  /// Combined sync word.
  static const int syncWord = 0x5AA5;

  /// Full on-wire packet length (sync + payload, no CRC).
  static const int totalPacketLength = 33;

  /// Payload bytes following the sync word.
  static const int payloadLength = 31;
}

/// Uplink magic `47 43` ('GC').
const int segfaultMagicG = 0x47;
const int segfaultMagicC = 0x43;

/// Codec for 33-byte SegFault packets (LE, no CRC).
abstract final class SegfaultPacketCodec {
  static const double baseLatitudeDeg = 49.7983333333;
  static const double baseLongitudeDeg = 16.6866666667;

  static const double accelGPerLsb = 1 / 2048.0;
  static const double gyroDpsPerLsb = 1 / 16.4;
  static const double gravityMps2 = 9.80665;
  static const double gpsOffsetScaleDeg = 1e-5;
  static const double batteryVoltPerLsb = 0.02;

  /// Decodes one full 33-byte packet (sync included) into an internal frame.
  ///
  /// Returns `null` for wrong lengths or a bad sync word. Any state id is
  /// accepted (unmapped ids surface as unknown via `stateForId`).
  /// When [assumeGpsFix] is false (demo firmware with `EnableGps = false`),
  /// the frame carries no fix flags — offsets still decode to base+offset
  /// (zero while GPS is disabled), but consumers see "no fix".
  static TelemetryFrame? decode(
    Uint8List packet, {
    required int receivedAtMs,
    bool assumeGpsFix = true,
  }) {
    if (packet.length != SegfaultFraming.totalPacketLength) return null;
    final b = ByteData.sublistView(packet);
    if (b.getUint16(0, Endian.little) != SegfaultFraming.syncWord) {
      return null;
    }
    final packetId = b.getUint8(4);
    final stateFlags = b.getUint8(5);

    final accelX = b.getInt16(6, Endian.little) * accelGPerLsb * gravityMps2;
    final accelY = b.getInt16(8, Endian.little) * accelGPerLsb * gravityMps2;
    final accelZ = b.getInt16(10, Endian.little) * accelGPerLsb * gravityMps2;
    final gyroX = b.getInt16(12, Endian.little) * gyroDpsPerLsb;
    final gyroY = b.getInt16(14, Endian.little) * gyroDpsPerLsb;
    final gyroZ = b.getInt16(16, Endian.little) * gyroDpsPerLsb;

    final aglM = b.getInt16(18, Endian.little) / 10.0;
    // rawPressure (u16 @20, Pa = raw*2) and tribo (u16 @22, V = raw*0.001)
    // have no internal field and are dropped.
    final batteryV = b.getUint8(24) * batteryVoltPerLsb;
    final latOff = b.getInt16(25, Endian.little);
    final lonOff = b.getInt16(27, Endian.little);
    final verticalUpMps = b.getInt16(29, Endian.little) / 10.0;
    final ky024 = b.getUint16(31, Endian.little);

    // Same gravity projection the old web client used to derive attitude
    // from the accel vector (yaw is underivable from accel alone).
    final rollRad = math.atan2(accelY, accelZ);
    final pitchRad = math.atan2(
      -accelX,
      math.sqrt(accelY * accelY + accelZ * accelZ),
    );
    const rad2deg = 180 / math.pi;

    return TelemetryFrame(
      receivedAtMs: receivedAtMs,
      // No fix flags on the wire; offsets default to the base when the
      // GPS is invalid, so OG frames assume a fix (see module doc).
      // Demo firmware disables GPS entirely — same bytes, no fix.
      flags: assumeGpsFix ? FrameFlags.gpsFix | FrameFlags.gpsFix3d : 0,
      sequence: packetId,
      latitude: baseLatitudeDeg + latOff * gpsOffsetScaleDeg,
      longitude: baseLongitudeDeg + lonOff * gpsOffsetScaleDeg,
      gpsAltitude: 0,
      baroAltitude: aglM,
      velocityNorth: 0,
      velocityEast: 0,
      velocityDown: -verticalUpMps,
      accelX: accelX,
      accelY: accelY,
      accelZ: accelZ,
      gyroX: gyroX,
      gyroY: gyroY,
      gyroZ: gyroZ,
      heading: 0,
      roll: rollRad * rad2deg,
      pitch: pitchRad * rad2deg,
      yaw: 0,
      batteryVoltage: batteryV,
      hallRaw: ky024,
      fsmStateId: stateFlags,
    );
  }

  /// Encodes field values into one full 33-byte packet (sync included).
  ///
  /// Test/bring-up helper only — the rocket is the canonical encoder.
  static Uint8List encodePacket({
    int timestampMs = 0,
    int packetId = 0,
    int stateFlags = 0,
    double accelXMps2 = 0,
    double accelYMps2 = 0,
    double accelZMps2 = gravityMps2,
    double gyroXDps = 0,
    double gyroYDps = 0,
    double gyroZDps = 0,
    double aglM = 0,
    int rawPressure = 0,
    int triboMv = 0,
    double batteryV = 0,
    double latitude = baseLatitudeDeg,
    double longitude = baseLongitudeDeg,
    double verticalUpMps = 0,
    int ky024 = 0,
  }) {
    final out = Uint8List(SegfaultFraming.totalPacketLength);
    final b = ByteData.sublistView(out);
    b.setUint16(0, SegfaultFraming.syncWord, Endian.little);
    b.setUint16(2, timestampMs & 0xFFFF, Endian.little);
    b.setUint8(4, packetId & 0xFF);
    b.setUint8(5, stateFlags & 0xFF);
    b.setInt16(
      6,
      _clampI16((accelXMps2 / (accelGPerLsb * gravityMps2)).round()),
      Endian.little,
    );
    b.setInt16(
      8,
      _clampI16((accelYMps2 / (accelGPerLsb * gravityMps2)).round()),
      Endian.little,
    );
    b.setInt16(
      10,
      _clampI16((accelZMps2 / (accelGPerLsb * gravityMps2)).round()),
      Endian.little,
    );
    b.setInt16(
      12,
      _clampI16((gyroXDps / gyroDpsPerLsb).round()),
      Endian.little,
    );
    b.setInt16(
      14,
      _clampI16((gyroYDps / gyroDpsPerLsb).round()),
      Endian.little,
    );
    b.setInt16(
      16,
      _clampI16((gyroZDps / gyroDpsPerLsb).round()),
      Endian.little,
    );
    b.setInt16(18, _clampI16((aglM * 10).round()), Endian.little);
    b.setUint16(20, rawPressure.clamp(0, 0xFFFF), Endian.little);
    b.setUint16(22, triboMv.clamp(0, 0xFFFF), Endian.little);
    b.setUint8(24, (batteryV / batteryVoltPerLsb).round().clamp(0, 0xFF));
    b.setInt16(
      25,
      _clampI16(((latitude - baseLatitudeDeg) / gpsOffsetScaleDeg).round()),
      Endian.little,
    );
    b.setInt16(
      27,
      _clampI16(((longitude - baseLongitudeDeg) / gpsOffsetScaleDeg).round()),
      Endian.little,
    );
    b.setInt16(29, _clampI16((verticalUpMps * 10).round()), Endian.little);
    b.setUint16(31, ky024.clamp(0, 0xFFFF), Endian.little);
    return out;
  }

  static int _clampI16(int v) => v.clamp(-0x8000, 0x7FFF);
}

/// Stateful SegFault stream parser: LE sync-hunt + fixed-length framing.
///
/// There is no CRC on the wire, so every 33-byte frame behind a sync word
/// is accepted; `crcErrorCount`/`crcErrorBytes` stay 0.
///
/// When [assumeGpsFix] is false, decoded frames carry no GPS fix flags
/// (demo firmware with GPS disabled) — same bytes, same positions.
class SegfaultConnectorParser extends ConnectorStreamParser {
  SegfaultConnectorParser({this.assumeGpsFix = true});

  /// Whether decoded frames assume a GPS fix (OG firmware) or report no
  /// fix (demo firmware, `AvionicsConfig::EnableGps = false`).
  final bool assumeGpsFix;

  final _buf = <int>[];

  @override
  int totalBytes = 0;

  @override
  int matchedPackets = 0;

  @override
  int matchedBytes = 0;

  @override
  int garbageBytes = 0;

  @override
  int crcErrorCount = 0;

  @override
  int crcErrorBytes = 0;

  @override
  List<TelemetryFrame> feed(Uint8List chunk, {int? timestampMs}) {
    totalBytes += chunk.length;
    _buf.addAll(chunk);
    final frames = <TelemetryFrame>[];
    final nowMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;

    while (_buf.length >= SegfaultFraming.totalPacketLength) {
      final start = _indexOfSync();
      if (start == -1) {
        garbageBytes += _buf.length - 1;
        final last = _buf.last;
        _buf.clear();
        _buf.add(last);
        break;
      }
      if (start > 0) {
        garbageBytes += start;
        _buf.removeRange(0, start);
      }
      if (_buf.length < SegfaultFraming.totalPacketLength) break;

      final packet = Uint8List.fromList(
        _buf.sublist(0, SegfaultFraming.totalPacketLength),
      );
      _buf.removeRange(0, SegfaultFraming.totalPacketLength);

      final frame = SegfaultPacketCodec.decode(
        packet,
        receivedAtMs: nowMs,
        assumeGpsFix: assumeGpsFix,
      );
      if (frame == null) {
        // Sync validated above; unreachable unless the buffer raced.
        // Count it as garbage so health counters stay consistent.
        garbageBytes += SegfaultFraming.totalPacketLength;
        continue;
      }
      matchedPackets++;
      matchedBytes += SegfaultFraming.totalPacketLength;
      frames.add(frame);
    }
    return frames;
  }

  @override
  void reset() => _buf.clear();

  @override
  void resetStats() {
    _buf.clear();
    totalBytes = 0;
    matchedPackets = 0;
    matchedBytes = 0;
    garbageBytes = 0;
    crcErrorCount = 0;
    crcErrorBytes = 0;
  }

  int _indexOfSync() {
    final limit = _buf.length - 1;
    for (var i = 0; i < limit; i++) {
      if (_buf[i] == SegfaultFraming.startByte0 &&
          _buf[i + 1] == SegfaultFraming.startByte1) {
        return i;
      }
    }
    return -1;
  }
}

/// The SegFault connector: OG rocket format, partial internal frame.
///
/// GPS altitude is never transmitted (capability off, field stays 0);
/// everything else is populated (attitude + horizontal velocity derived,
/// see the codec).
class SegfaultConnector extends TelemetryConnector {
  const SegfaultConnector();

  @override
  String get id => 'segfault';

  @override
  String get displayName => 'Rocket v1';

  @override
  String get description => 'Connector for the flight version of the v1 rocket';

  @override
  ConnectorStreamParser createParser() => SegfaultConnectorParser();

  @override
  int get framingPayloadLength => SegfaultFraming.payloadLength;
  static const List<ConnectorFsmState> _states = [
    ConnectorFsmState(
      id: 0,
      label: 'Before Launch',
      colorArgb: 0xFF7F788D,
      hasNosecone: true,
      hasParachute: false,
      showsParachute: false,
    ),
    ConnectorFsmState(
      id: 1,
      label: 'Armed',
      colorArgb: 0xFFE03434,
      hasNosecone: true,
      hasParachute: false,
      showsParachute: false,
    ),
    ConnectorFsmState(
      id: 2,
      label: 'Flight',
      colorArgb: 0xFFF0B400,
      hasNosecone: true,
      hasParachute: false,
      showsParachute: false,
    ),
    ConnectorFsmState(
      id: 3,
      label: 'Apogee Reached',
      colorArgb: 0xFFF07D12,
      hasNosecone: false,
      hasParachute: false,
      showsParachute: false,
    ),
    ConnectorFsmState(
      id: 4,
      label: 'Chute Deployed',
      colorArgb: 0xFF0DA39A,
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

  @override
  List<ConnectorCommand> get commands => const [
    ConnectorCommand(
      id: 'deploy_parachute',
      label: 'Deploy chute',
      description: 'Deploy the parachute servo (release nose-cone latches)',
      bytes: [segfaultMagicG, segfaultMagicC, 0xAA, 0x00],
      danger: true,
    ),
    ConnectorCommand(
      id: 'stow_parachute',
      label: 'Stow chute',
      description: 'Stow the parachute servo (lock nose-cone latches)',
      bytes: [segfaultMagicG, segfaultMagicC, 0x55, 0x00],
    ),
    ConnectorCommand(
      id: 'reset_baseline',
      label: 'Reset baseline',
      description: 'Reset sensor baseline (only before flight)',
      bytes: [segfaultMagicG, segfaultMagicC, 0x67, 0x67],
      danger: true,
    ),
  ];

  static bool _isKnownStateId(int id) => id >= 0 && id <= 4;

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

  @override
  List<ConnectorEventDef> get events => const [
        ConnectorEventDef(label: 'Launch', fromStateId: 1, toStateId: 2),
        ConnectorEventDef(
          label: 'Apogee',
          fromStateId: 2,
          toStateId: 3,
          // Firmware without an apogee state jumps straight here.
          additionalTransitions: [ConnectorTransition(2, 4)],
        ),
        ConnectorEventDef(label: 'Parachute', fromStateId: 3, toStateId: 4),
      ];

  @override
  FieldCapabilities get capabilities => const FieldCapabilities({
    TelemetryField.gpsPosition,
    TelemetryField.baroAltitude,
    TelemetryField.velocity,
    TelemetryField.acceleration,
    TelemetryField.gyro,
    TelemetryField.attitude,
    TelemetryField.battery,
    TelemetryField.hall,
    TelemetryField.fsm,
  });
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
