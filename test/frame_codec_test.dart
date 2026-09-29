import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('crc16CCITT', () {
    test('matches the CCITT-FALSE check vector', () {
      // Standard check value for CRC-16/CCITT-FALSE.
      final bytes = Uint8List.fromList('123456789'.codeUnits);
      expect(crc16CCITT(bytes), 0x29B1);
    });

    test('covers partial ranges', () {
      final bytes = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      expect(crc16CCITT(bytes, 1, 3), crc16CCITT(bytes.sublist(1, 3)));
    });
  });

  group('FrameCodec', () {
    final frame = TelemetryFrame(
      receivedAtMs: 1700000000000,
      sequence: 513,
      latitude: 50.0755,
      longitude: -14.4378,
      baroAltitude: 812.34,
      velocityNorth: 12.34,
      velocityEast: -3.21,
      velocityUp: 45.6,
      accelX: 1.5,
      accelY: -2.5,
      accelZ: 65.4,
      gyroX: 10.5,
      gyroY: -20.5,
      gyroZ: 240.0,
      heading: 275.32,
      roll: 123.45,
      pitch: 12.34,
      yaw: -95.5,
      batteryVoltage: 8.36,
      hallRaw: 2543,
      fsmStateId: FsmState.parachute.id,
    );

    test('encode → decode round-trips within quantization tolerance', () {
      final payload = FrameCodec.encode(frame);
      expect(payload.length, TelemetryFraming.payloadLength);

      final decoded =
          FrameCodec.decode(payload, receivedAtMs: 42)!;

      expect(decoded.sequence, 513);
      expect(decoded.latitude, closeTo(50.0755, 1e-6));
      expect(decoded.longitude, closeTo(-14.4378, 1e-6));
      expect(decoded.baroAltitude, closeTo(812.34, 0.01));
      expect(decoded.velocityNorth, closeTo(12.34, 0.01));
      expect(decoded.velocityEast, closeTo(-3.21, 0.01));
      expect(decoded.velocityUp, closeTo(45.6, 0.01));
      expect(decoded.accelX, closeTo(1.5, 0.02));
      expect(decoded.accelY, closeTo(-2.5, 0.02));
      expect(decoded.accelZ, closeTo(65.4, 0.05));
      expect(decoded.gyroZ, closeTo(240.0, 0.01));
      expect(decoded.heading, closeTo(275.32, 0.01));
      expect(decoded.roll, closeTo(123.45, 0.01));
      expect(decoded.pitch, closeTo(12.34, 0.01));
      expect(decoded.yaw, closeTo(-95.5, 0.01));
      expect(decoded.batteryVoltage, closeTo(8.36, 0.001));
      expect(decoded.hallRaw, 2543);
      expect(decoded.fsmState, FsmState.parachute);
      expect(decoded.receivedAtMs, 42);
    });

    test('negative vertical accel round-trips with sign preserved', () {
      const probe = TelemetryFrame(accelX: 0.5, accelY: -0.3, accelZ: -12.7);
      final decoded =
          FrameCodec.decode(FrameCodec.encode(probe), receivedAtMs: 0)!;
      expect(decoded.accelVertical, closeTo(-12.7, 0.05));
      expect(decoded.accelVertical, lessThan(0));
      // Total stays a non-negative magnitude over the same sample.
      expect(
        decoded.accelTotal,
        closeTo(
          math.sqrt(0.5 * 0.5 + 0.3 * 0.3 + 12.7 * 12.7),
          0.05,
        ),
      );
    });

    test('encodePacket prepends the sync word', () {
      final packet = FrameCodec.encodePacket(frame);
      expect(packet.length, TelemetryFraming.totalPacketLength);
      expect(packet[0], 0xAA);
      expect(packet[1], 0x55);
      expect(
        packet.sublist(2),
        FrameCodec.encode(frame),
      );
    });

    test('decode rejects a corrupted payload', () {
      final payload = FrameCodec.encode(frame);
      payload[10] ^= 0xFF; // corrupt one GPS byte
      expect(FrameCodec.decode(payload, receivedAtMs: 0), isNull);
      expect(FrameCodec.verifyCrc(payload), isFalse);
    });

    test('decode rejects wrong lengths', () {
      expect(
        FrameCodec.decode(Uint8List(10), receivedAtMs: 0),
        isNull,
      );

      final payload = FrameCodec.encode(frame);
      expect(
        FrameCodec.decode(payload.sublist(0, payload.length - 1),
            receivedAtMs: 0),
        isNull,
      );
    });

    test('encode clamps out-of-range values instead of wrapping', () {
      final wild = TelemetryFrame(
        receivedAtMs: 0,
        latitude: 999,
        longitude: 999,
        velocityNorth: 1e9,
        batteryVoltage: 1e6,
      );
      final decoded = FrameCodec.decode(FrameCodec.encode(wild), receivedAtMs: 0)!;
      expect(decoded.latitude, lessThanOrEqualTo(90));
      expect(decoded.longitude, lessThanOrEqualTo(180));
      expect(decoded.velocityNorth.abs(), lessThanOrEqualTo(327.68));
      expect(decoded.batteryVoltage, lessThanOrEqualTo(65.535));
      expect(decoded.latitude.isFinite, isTrue);
    });
  });

  group('FsmState', () {
    test('maps known ids and falls back to unknown', () {
      expect(FsmState.fromId(0), FsmState.idle);
      expect(FsmState.fromId(2), FsmState.ascent);
      expect(FsmState.fromId(4), FsmState.parachute);
      expect(FsmState.fromId(5), FsmState.landed);
      expect(FsmState.fromId(7), FsmState.debugLocked);
      expect(FsmState.fromId(200), FsmState.unknown);
    });

    test('ids are unique', () {
      final ids = FsmState.values.map((s) => s.id).toSet();
      expect(ids.length, FsmState.values.length);
    });
  });
}
