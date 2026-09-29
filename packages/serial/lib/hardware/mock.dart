import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../telemetry/flight_simulator.dart';
import '../telemetry/frame_codec.dart';

/// Unknown-traffic phase of the mock's 20 s interference cycle (@10 Hz):
/// 12 s clean air, 4 s light unknown bytes (~150 B/s, "activity"), 4 s heavy
/// noise + periodic CRC-corrupted clones (~500+ B/s, "interference").
///
/// The cycle lets the channel-health monitor demo every verdict without any
/// radio hardware: connect MOCK, open Channel health and watch it sweep
/// clear → activity → interference every 20 seconds.
enum MockInterferencePhase { clean, light, heavy }

/// Phase for the [tick]-th 100 ms emission tick (0-based).
MockInterferencePhase mockPhaseForTick(int tick) {
  final t = tick % 200;
  if (t < 120) return MockInterferencePhase.clean;
  if (t < 160) return MockInterferencePhase.light;
  return MockInterferencePhase.heavy;
}

/// Extra non-decodable bytes the mock emits alongside tick [tick]'s valid
/// packet (`null` when the phase is clean). Heavy ticks every 5th emission
/// also get a bit-flipped clone of the real packet appended by [connect],
/// exercising the CRC-error path.
Uint8List? mockInterferenceBytes(int tick, math.Random random) {
  switch (mockPhaseForTick(tick)) {
    case MockInterferencePhase.clean:
      return null;
    case MockInterferencePhase.light:
      return Uint8List.fromList(
          List.generate(15, (_) => random.nextInt(256)));
    case MockInterferencePhase.heavy:
      return Uint8List.fromList(
          List.generate(50, (_) => random.nextInt(256)));
  }
}

/// A mock implementation of a serial communication service.
///
/// Simulates an incoming stream of realistic flight telemetry driven by
/// [FlightSimulator] without requiring physical serial hardware or COM ports.
/// Useful for UI development, automated testing, and offline demonstrations.
///
/// Every `connect()` starts a fresh simulated flight (GPS cold start → pad →
/// boost → coast → chute → landed). Frames are emitted at 10 Hz as
/// properly framed wire packets.
class MockSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;
  FlightSimulator? _simulator;
  int _tick = 0;
  final math.Random _random = math.Random();

  /// Identifier used to select the mock port in UI dropdowns.
  static String get portName => 'MOCK';

  /// Broadcast stream controller emitting simulated incoming byte chunks.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming simulated telemetry byte buffers.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether the mock connection is currently active and producing data.
  bool get isConnected => _isConnected;

  /// Starts the mock connection and begins emitting simulated flight frames.
  bool connect() {
    disconnect();
    _isConnected = true;
    _simulator = FlightSimulator();
    _tick = 0;

    const tick = Duration(milliseconds: 100);
    _mockTimer = Timer.periodic(tick, (_) {
      if (!_isConnected) return;

      final frame = _simulator!.step(tick.inMilliseconds / 1000);
      final packet = FrameCodec.encodePacket(frame);
      _byteStreamController.add(packet);

      // Cyclic unknown traffic so the channel-health monitor has something
      // to show (see [mockPhaseForTick]).
      final noise = mockInterferenceBytes(_tick, _random);
      if (noise != null) _byteStreamController.add(noise);
      if (mockPhaseForTick(_tick) == MockInterferencePhase.heavy &&
          _tick % 5 == 0) {
        // Bit-flipped clone: frames but fails CRC (exercises crcErrorBytes).
        final corrupted = Uint8List.fromList(packet);
        corrupted[10] ^= 0xFF;
        _byteStreamController.add(corrupted);
      }
      _tick++;
    });

    return true;
  }

  /// Terminates the mock connection and cancels the data generation timer.
  void disconnect() {
    _isConnected = false;
    _mockTimer?.cancel();
    _mockTimer = null;
    _simulator = null;
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
