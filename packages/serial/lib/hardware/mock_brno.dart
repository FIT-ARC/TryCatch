import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../telemetry/frame_codec.dart';
import '../telemetry/telemetry_frame.dart';

/// Brno static pad coordinates (WGS84 degrees).
const double mockBrnoLatitude = 49.22892339423079;

/// Brno static pad coordinates (WGS84 degrees).
const double mockBrnoLongitude = 16.582853748863815;

/// Altitude above the launch site in metres. Zero: the rocket sits on the pad,
/// so absolute MSL resolves as site MSL + 18 — select the `Brno Pad` launch
/// site (264 m MSL) to read 264 m MSL downstream.
const double mockBrnoBaroAltitude = 18;

/// Metres per degree of latitude (WGS84 mean, enough for 1 m test nudges).
const double mockBrnoMetersPerDegLat = 111320.0;

/// Ticks per parachute half-period at the 10 Hz emission cadence (5 s off,
/// 5 s on, 10 s full period).
const int mockBrnoToggleTicks = 50;

/// Full Brno toggle period in 100 ms ticks (@10 Hz).
const int mockBrnoPeriodTicks = mockBrnoToggleTicks * 2;

/// Returns `true` when tick [tick] (0-based, 100 ms cadence) falls in the
/// parachute-on half of the cycle.
bool mockBrnoParachuteForTick(int tick) {
  final t = tick % mockBrnoPeriodTicks;
  return t >= mockBrnoToggleTicks;
}

/// Uplink command byte moving the reported position up by 1 m.
const int mockBrnoMoveUpCmd = 0x10;

/// Uplink command byte moving the reported position down by 1 m.
const int mockBrnoMoveDownCmd = 0x11;

/// Uplink command byte moving the reported position east by 1 m.
const int mockBrnoMoveEastCmd = 0x12;

/// Uplink command byte moving the reported position west by 1 m.
const int mockBrnoMoveWestCmd = 0x13;

/// A static mock serial port for testing downstream software.
///
/// Emits the same [TelemetryFrame] at 10 Hz with no noise, no drift and no
/// interference traffic: fixed GPS, zero velocity, level attitude, constant
/// battery — only the FSM state toggles between idle (parachute off) and
/// parachute (parachute on) every [mockBrnoToggleTicks] ticks so the
/// `hasParachute` bit flips as a clean square wave. Uplink frames matching
/// the Brno move commands shift the reported position by 1 m per command
/// (up/down on baro altitude, east/west on longitude) independently of the
/// FSM state, so map and altitude tiles move visibly.
///
/// Uses the shared `mock` connector wire format ([FrameCodec]) like the other
/// MOCK ports.
class MockBrnoSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;
  int _tick = 0;
  int _seq = 0;
  double _latOffsetDeg = 0;
  double _lonOffsetDeg = 0;
  double _altOffsetM = 0;

  /// Identifier used to select the Brno static port in UI dropdowns.
  static String get portName => 'Brno';

  /// Broadcast stream controller emitting simulated incoming byte chunks.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming simulated telemetry byte buffers.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether the mock connection is currently active and producing data.
  bool get isConnected => _isConnected;

  /// Starts the mock connection and begins emitting static frames.
  bool connect() {
    disconnect();
    _isConnected = true;
    _tick = 0;
    _seq = 0;
    _latOffsetDeg = 0;
    _lonOffsetDeg = 0;
    _altOffsetM = 0;

    const tick = Duration(milliseconds: 100);
    _mockTimer = Timer.periodic(tick, (_) {
      if (!_isConnected) return;

      final parachute = mockBrnoParachuteForTick(_tick);
      _tick++;
      _seq++;
      final frame = TelemetryFrame(
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        flags: FrameFlags.gpsFix,
        sequence: _seq,
        latitude: mockBrnoLatitude + _latOffsetDeg,
        longitude: mockBrnoLongitude + _lonOffsetDeg,
        baroAltitude: mockBrnoBaroAltitude + _altOffsetM,
        velocityNorth: 0,
        velocityEast: 0,
        velocityUp: 0,
        accelX: 0,
        accelY: 0,
        accelZ: 9.81,
        gyroX: 0,
        gyroY: 0,
        gyroZ: 0,
        heading: 0,
        roll: 0,
        pitch: 0,
        yaw: 0,
        batteryVoltage: 8.4,
        hallRaw: 2500,
        fsmStateId: parachute ? FsmState.parachute.id : FsmState.idle.id,
      );
      _byteStreamController.add(FrameCodec.encodePacket(frame));
    });

    return true;
  }

  /// Terminates the mock connection and cancels the data generation timer.
  void disconnect() {
    _isConnected = false;
    _mockTimer?.cancel();
    _mockTimer = null;
  }

  /// Applies one uplink [bytes] frame to the reported position.
  ///
  /// Returns `true` if connected, simulating successful transmission.
  bool sendBytes(Uint8List bytes) {
    if (!_isConnected) return false;
    if (bytes.length == 4 && bytes[0] == 0x54 && bytes[1] == 0x43) {
      switch (bytes[2]) {
        case mockBrnoMoveUpCmd:
          _altOffsetM += 1;
        case mockBrnoMoveDownCmd:
          _altOffsetM -= 1;
        case mockBrnoMoveEastCmd:
          _lonOffsetDeg += _metersEastToDeg(1);
        case mockBrnoMoveWestCmd:
          _lonOffsetDeg -= _metersEastToDeg(1);
      }
    }
    return true;
  }

  double _metersEastToDeg(double meters) {
    final latRad =
        (mockBrnoLatitude + _latOffsetDeg) * math.pi / 180;
    return meters / (mockBrnoMetersPerDegLat * math.cos(latRad));
  }
}
