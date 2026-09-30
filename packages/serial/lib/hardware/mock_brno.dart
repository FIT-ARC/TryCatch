import 'dart:async';
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

/// A static mock serial port for testing downstream software.
///
/// Emits the same [TelemetryFrame] at 10 Hz with no noise, no drift and no
/// interference traffic: fixed GPS, zero velocity, level attitude, constant
/// battery — only the FSM state toggles between idle (parachute off) and
/// parachute (parachute on) every [mockBrnoToggleTicks] ticks so the
/// `hasParachute` bit flips as a clean square wave.
///
/// Uses the shared `mock` connector wire format ([FrameCodec]) like the other
/// MOCK ports.
class MockBrnoSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;
  int _tick = 0;
  int _seq = 0;

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
        latitude: mockBrnoLatitude,
        longitude: mockBrnoLongitude,
        baroAltitude: mockBrnoBaroAltitude,
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

  /// Simulates transmitting [bytes] across the mock connection.
  ///
  /// Returns `true` if connected, simulating successful transmission.
  bool sendBytes(Uint8List bytes) {
    if (!_isConnected) return false;
    // Acknowledge sent bytes in mock mode
    return true;
  }
}
