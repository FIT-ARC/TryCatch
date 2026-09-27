import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../telemetry/flight_simulator.dart';
import '../telemetry/frame_codec.dart';
import 'mock.dart';

/// A chaos mock serial port for testing the app's failure UX.
///
/// Behaves like [MockSerialPort] (same [FlightSimulator] flight + same 20 s
/// unknown-traffic interference cycle) but misbehaves at random, exercising
/// every serial-error path without any radio hardware:
/// - [connectFailureRate]: `connect()` randomly refuses the open, so the
///   worker answers `Failed to open MOCK-DC` (error toast + connecting pill
///   clearing).
/// - [dropPerTick]: every 100 ms tick randomly kills the link dead (timer
///   cancelled, handle down, stays down until reconnect) like a yanked USB
///   adapter, so the worker watchdog reports `Port disconnected` (warning
///   toast + picker unlocking).
/// - [sendFailureRate]: `sendBytes` randomly NAKs while the link stays up —
///   the half-open "receives but can't send" state — so uplinks land in the
///   command log as failed with a `Command failed` toast.
///
/// All three rates are probabilities in [0, 1] (defaults tuned for manual
/// testing: a refused open roughly every third try, a drop every ~25 s on
/// average, one failed uplink in ten). Tests pin them to 0.0/1.0 for
/// determinism; pass [random] for a reproducible session.
class MockDcSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;
  FlightSimulator? _simulator;
  int _tick = 0;
  final math.Random _random;

  /// Probability that [connect] refuses the open.
  final double connectFailureRate;

  /// Probability per 100 ms tick that a live link drops dead.
  final double dropPerTick;

  /// Probability that [sendBytes] fails while connected.
  final double sendFailureRate;

  MockDcSerialPort({
    math.Random? random,
    this.connectFailureRate = 0.3,
    this.dropPerTick = 0.004,
    this.sendFailureRate = 0.1,
  })  : _random = random ?? math.Random(),
        assert(connectFailureRate >= 0 && connectFailureRate <= 1),
        assert(dropPerTick >= 0 && dropPerTick <= 1),
        assert(sendFailureRate >= 0 && sendFailureRate <= 1);

  /// Identifier used to select the chaos mock port in UI dropdowns.
  static String get portName => 'MOCK-DC';

  /// Broadcast stream controller emitting simulated incoming byte chunks.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming simulated telemetry byte buffers.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether the mock connection is currently active and producing data.
  bool get isConnected => _isConnected;

  /// Starts the mock connection unless the chaos roll refuses the open.
  ///
  /// Every call starts a fresh simulated flight. A refused open leaves the
  /// port fully down (`false`, [isConnected] stays `false`).
  bool connect() {
    disconnect();
    if (_random.nextDouble() < connectFailureRate) return false;
    _isConnected = true;
    _simulator = FlightSimulator();
    _tick = 0;

    const tick = Duration(milliseconds: 100);
    _mockTimer = Timer.periodic(tick, (_) {
      if (!_isConnected) return;

      // Random hard drop: the link dies here and stays dead (no packets,
      // no noise) until the user reconnects — the worker watchdog, not the
      // byte stream, is what reports it.
      if (_random.nextDouble() < dropPerTick) {
        disconnect();
        return;
      }

      final frame = _simulator!.step(tick.inMilliseconds / 1000);
      final packet = FrameCodec.encodePacket(frame);
      _byteStreamController.add(packet);

      // Same cyclic unknown traffic as the clean MOCK port.
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
  /// Randomly fails per [sendFailureRate] while staying connected (the
  /// half-open TX stall); always fails while down.
  bool sendBytes(Uint8List bytes) {
    if (!_isConnected) return false;
    if (_random.nextDouble() < sendFailureRate) return false;
    return true;
  }
}
