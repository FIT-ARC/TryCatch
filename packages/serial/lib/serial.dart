/// Library for communicating over serial ports.
library;

export 'connectors/connector.dart';
export 'connectors/mock_connector.dart';
export 'connectors/registry.dart';
export 'connectors/segfault_connector.dart';
export 'connectors/segfault_demo_connector.dart';
export 'constants.dart';
export 'hardware/mock.dart';
export 'hardware/mock_bq.dart';
export 'hardware/mock_dc.dart';
export 'hardware/real.dart';
export 'io/file_parser.dart';
export 'io/packet_parser.dart';
export 'io/recorder.dart';
export 'io/recording_file.dart';
export 'telemetry/frame_codec.dart';
export 'telemetry/flight_simulator.dart';
export 'telemetry/rocket_commands.dart';
export 'telemetry/sent_command.dart';
export 'telemetry/telemetry_frame.dart';
export 'worker/manager.dart';
export 'worker/protocol.dart';

import 'dart:async';
import 'dart:typed_data';

import 'connectors/registry.dart' show isDevMode;
import 'hardware/mock.dart';
import 'hardware/mock_bq.dart';
import 'hardware/mock_dc.dart';
import 'hardware/real.dart';

/// Unified serial communication service coordinating physical hardware
/// ([RealSerialPort]) and simulated telemetry ([MockSerialPort],
/// [MockBqSerialPort], [MockDcSerialPort]).
class SerialService {
  final RealSerialPort _realPort = RealSerialPort();
  final MockSerialPort _mockPort = MockSerialPort();
  final MockBqSerialPort _mockBqPort = MockBqSerialPort();
  final MockDcSerialPort _mockDcPort = MockDcSerialPort();

  StreamSubscription<Uint8List>? _realSubscription;
  StreamSubscription<Uint8List>? _mockSubscription;

  /// Name of the active mock port ([MockSerialPort.portName] /
  /// [MockBqSerialPort.portName] / [MockDcSerialPort.portName]), or `null`
  /// when the real port is active.
  String? _activeMockName;

  bool get _isMockActive => _activeMockName != null;

  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of raw incoming [Uint8List] byte chunks from the active port.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Returns a combined list of all detected physical ports and — in debug
  /// builds only — the virtual mock ports (MOCK + MOCK-BQ + MOCK-DC).
  ///
  /// `connect()` still accepts the mock names in every build (tests and
  /// replay tooling rely on it); they are just not *listed* outside dev mode.
  /// Never throws: a failing OS enumeration yields just the mock names.
  static List<String> get availablePorts {
    List<String> physical;
    try {
      physical = RealSerialPort.availablePorts;
    } catch (_) {
      physical = const [];
    }
    return [
      if (isDevMode) ...[
        MockSerialPort.portName,
        MockBqSerialPort.portName,
        MockDcSerialPort.portName,
      ],
      ...physical,
    ];
  }

  /// Whether [portName] selects one of the dev-only virtual mock ports.
  static bool isMockPortName(String portName) =>
      portName == MockSerialPort.portName ||
      portName == MockBqSerialPort.portName ||
      portName == MockDcSerialPort.portName;

  /// Whether a connection is currently active (physical or virtual).
  bool get isConnected {
    if (_activeMockName == MockBqSerialPort.portName) {
      return _mockBqPort.isConnected;
    }
    if (_activeMockName == MockDcSerialPort.portName) {
      return _mockDcPort.isConnected;
    }
    if (_activeMockName != null) return _mockPort.isConnected;
    return _realPort.isConnected;
  }

  /// Establishes a serial connection to [portName] (physical COM port or
  /// virtual MOCK / MOCK-BQ / MOCK-DC).
  bool connect(String portName) {
    disconnect();

    if (SerialService.isMockPortName(portName)) {
      _activeMockName = portName;
      final isBq = portName == MockBqSerialPort.portName;
      final isDc = portName == MockDcSerialPort.portName;
      final mockStream = isBq
          ? _mockBqPort.byteStream
          : (isDc ? _mockDcPort.byteStream : _mockPort.byteStream);
      _mockSubscription = mockStream.listen((data) {
        if (_isMockActive) {
          _byteStreamController.add(data);
        }
      });
      if (isBq) return _mockBqPort.connect();
      if (isDc) return _mockDcPort.connect();
      return _mockPort.connect();
    }

    _activeMockName = null;
    _realSubscription = _realPort.byteStream.listen((data) {
      if (!_isMockActive) {
        _byteStreamController.add(data);
      }
    });

    final ok = _realPort.connect(portName);
    if (!ok) {
      disconnect();
    }
    return ok;
  }

  /// Disconnects the active serial connection and resets stream forwarders.
  void disconnect() {
    _mockSubscription?.cancel();
    _mockSubscription = null;
    _realSubscription?.cancel();
    _realSubscription = null;

    if (_isMockActive) {
      _mockPort.disconnect();
      _mockBqPort.disconnect();
      _mockDcPort.disconnect();
      _activeMockName = null;
    } else {
      _realPort.disconnect();
    }
  }

  /// Transmits raw [bytes] over the active connection.
  bool sendBytes(Uint8List bytes) {
    if (!isConnected) return false;
    if (_activeMockName == MockBqSerialPort.portName) {
      return _mockBqPort.sendBytes(bytes);
    }
    if (_activeMockName == MockDcSerialPort.portName) {
      return _mockDcPort.sendBytes(bytes);
    }
    return _isMockActive
        ? _mockPort.sendBytes(bytes)
        : _realPort.sendBytes(bytes);
  }
}
