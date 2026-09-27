import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../constants.dart';

/// Physical hardware implementation of serial port communication.
///
/// Directly manages native [SerialPort] handles, asynchronous [SerialPortReader]
/// stream listening, and hardware configuration applying [SerialHardwareConfig].
class RealSerialPort {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSubscription;

  /// Broadcast controller emitting raw incoming byte chunks from the physical port.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming raw byte chunks from the physical serial connection.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether a physical serial connection is currently open.
  bool get isConnected => _port != null && _port!.isOpen;

  /// List of detected physical serial ports available on the host OS.
  ///
  /// Never throws: `SerialPort.availablePorts` can throw on some Linux/macOS
  /// configurations (missing permissions, no udev, driver quirks). Callers
  /// (port scans in the worker isolate) must not crash the isolate.
  static List<String> get availablePorts {
    try {
      return SerialPort.availablePorts;
    } catch (_) {
      return const [];
    }
  }

  /// Opens and configures the physical serial port identified by [portName].
  bool connect(String portName) {
    disconnect();

    try {
      _port = SerialPort(portName);
      if (!_port!.openReadWrite()) {
        disconnect();
        return false;
      }

      // Configure hardware parameters from centralized constants.
      //
      // NOTE: mutating `_port.config` fields alone does NOT touch the port:
      // the `config` getter returns a cached in-memory struct and only the
      // `config` *setter* calls sp_set_config. Without the assignment below
      // the port keeps whatever baud the OS/driver had (e.g. 9600 left over
      // by another tool), which garbles every frame while the air link is
      // fine. Always assign back through the setter.
      //
      // The config is built fresh and applied in a single sp_set_config call.
      // Two things matter here:
      // 1. Flow control + modem lines are explicitly forced to off/none
      //    (see SerialHardwareConfig): leftover OS/driver defaults assert
      //    DTR/RTS or enable RTS/CTS on some ARM builds, which holds the
      //    LoRa MCU in reset (or stalls TX on floating CTS) until the
      //    adapter is physically re-enumerated (unplug/replug).
      // 2. One atomic apply avoids a glitch per field: assigning through the
      //    setter per field issues a full sp_set_config round-trip each,
      //    pulsing the lines once per field on drivers that re-assert
      //    control lines per reconfiguration.
      final config = SerialPortConfig()
        ..baudRate = SerialHardwareConfig.baudRate
        ..bits = SerialHardwareConfig.dataBits
        ..parity = SerialHardwareConfig.parity
        ..stopBits = SerialHardwareConfig.stopBits
        ..setFlowControl(SerialHardwareConfig.flowControl)
        ..rts = SerialHardwareConfig.rts
        ..cts = SerialHardwareConfig.cts
        ..dtr = SerialHardwareConfig.dtr
        ..dsr = SerialHardwareConfig.dsr
        ..xonXoff = SerialHardwareConfig.xonXoff;
      _port!.config = config;
      // Discard any bootloader blurb / line-glitch bytes produced by the
      // open + reconfigure sequence before the reader attaches.
      try {
        _port!.flush();
      } catch (_) {}

      // Attach native asynchronous stream reader
      _reader = SerialPortReader(_port!);
      _readerSubscription = _reader!.stream.listen(
        (data) {
          if (data.isNotEmpty) {
            _byteStreamController.add(data);
          }
        },
        onError: (_) => disconnect(),
        onDone: () => disconnect(),
      );

      return true;
    } catch (_) {
      disconnect();
      return false;
    }
  }

  /// Closes the physical serial port and cancels active reader threads.
  void disconnect() {
    _readerSubscription?.cancel();
    _readerSubscription = null;

    try {
      _reader?.close();
    } catch (_) {}
    _reader = null;

    if (_port != null) {
      try {
        if (_port!.isOpen) {
          _port!.close();
        }
        _port!.dispose();
      } catch (_) {}
      _port = null;
    }
  }

  /// Transmits raw [bytes] to the connected hardware port.
  ///
  /// Returns `true` only when the OS accepted every byte. A partial write
  /// means the handle is broken (unplugged mid-write, driver dropped the
  /// endpoint): the port is torn down so the worker's disconnect watchdog
  /// can report it instead of leaving a half-open "connected but can't
  /// send" state behind.
  bool sendBytes(Uint8List bytes) {
    if (!isConnected) return false;

    try {
      final written = _port!.write(bytes);
      if (written != bytes.length) {
        disconnect();
        return false;
      }
      return true;
    } catch (_) {
      disconnect();
      return false;
    }
  }
}
