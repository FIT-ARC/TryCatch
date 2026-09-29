/// Wire-format layout, encoding/decoding and CRC for telemetry frames.
library;

import 'dart:typed_data';

import '../constants.dart';
import 'telemetry_frame.dart';

/// Byte offsets and scales of every field inside a telemetry payload.
///
/// Payload layout (big-endian, 52 bytes, CRC included). There is a single
/// wire format — no versioning, no legacy layouts.
///
/// | Offset | Size | Field     | Type | Scale    | Notes                          |
/// |--------|------|-----------|------|----------|--------------------------------|
/// | 0      | 1    | flags     | u8   | bitfield | See [FrameFlags]               |
/// | 1      | 2    | seq       | u16  | —        | Rolling sequence number        |
/// | 3      | 4    | gpsLat    | i32  | 1e-7 deg | WGS84, positive North          |
/// | 7      | 4    | gpsLon    | i32  | 1e-7 deg | WGS84, positive East           |
/// | 11     | 4    | gpsAlt    | i32  | cm       | Legacy MSL, mirrors baro on encode, ignored on decode |
/// | 15     | 4    | baroAlt   | i32  | cm       | Above launch site              |
/// | 19     | 2    | velN      | i16  | cm/s     | NED: North                     |
/// | 21     | 2    | velE      | i16  | cm/s     | NED: East                      |
/// | 23     | 2    | velD      | i16  | cm/s     | NED: Down (positive down)      |
/// | 25     | 2    | accelX    | i16  | mg       | Body frame                     |
/// | 27     | 2    | accelY    | i16  | mg       | Body frame                     |
/// | 29     | 2    | accelZ    | i16  | mg       | Body frame, longitudinal       |
/// | 31     | 2    | gyroX     | i16  | centidps | Centi-degrees per second       |
/// | 33     | 2    | gyroY     | i16  | centidps |                                |
/// | 35     | 2    | gyroZ     | i16  | centidps | Longitudinal (±327 dps)        |
/// | 37     | 2    | heading   | u16  | 0.01 deg | Compass, [0, 360)              |
/// | 39     | 2    | roll      | i16  | centideg | Spin about longitudinal axis   |
/// | 41     | 2    | pitch     | i16  | centideg | Tilt from vertical             |
/// | 43     | 2    | yaw       | i16  | centideg | Nose heading, [-180, 180]      |
/// | 45     | 2    | battery   | u16  | mV       | Pack voltage                   |
/// | 47     | 2    | hall      | u16  | raw ADC  | Breakaway wire sensor (~2-3k)  |
/// | 49     | 1    | fsmState  | u8   | enum     | See [FsmState]                 |
/// | 50     | 2    | crc       | u16  | —        | CRC16-CCITT over bytes 0..49   |
abstract final class TelemetryLayout {
  static const int offsetFlags = 0;
  static const int offsetSeq = 1;
  static const int offsetGpsLat = 3;
  static const int offsetGpsLon = 7;
  static const int offsetGpsAlt = 11;
  static const int offsetBaroAlt = 15;
  static const int offsetVelN = 19;
  static const int offsetVelE = 21;
  static const int offsetVelD = 23;
  static const int offsetAccelX = 25;
  static const int offsetAccelY = 27;
  static const int offsetAccelZ = 29;
  static const int offsetGyroX = 31;
  static const int offsetGyroY = 33;
  static const int offsetGyroZ = 35;
  static const int offsetHeading = 37;
  static const int offsetRoll = 39;
  static const int offsetPitch = 41;
  static const int offsetYaw = 43;
  static const int offsetBattery = 45;
  static const int offsetHall = 47;
  static const int offsetFsmState = 49;

  /// Offset of the trailing CRC16 field inside the payload.
  static const int offsetCrc = payloadCrcOffset;

  /// Fixed-point scale: degrees stored as 1e-7 deg units.
  static const double latLonScale = 1e-7;

  /// Fixed-point scale: velocities stored in cm/s.
  static const double velocityScale = 0.01;

  /// Fixed-point scale: accelerations stored in milli-g.
  static const double accelScaleMg = 0.00980665;

  /// Fixed-point scale: gyro rates stored in centi-degrees/s (±327.67 dps).
  static const double gyroScale = 0.01;

  /// Fixed-point scale: heading stored in centi-degrees.
  static const double angleScale = 0.01;
}

/// CRC offset derived from the framing constants so layout and framing can
/// never drift apart.
const int payloadCrcOffset = TelemetryFraming.payloadLength - 2;

/// Computes CRC16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no xor-out)
/// over `bytes[start]` .. `bytes[end - 1]`.
int crc16CCITT(Uint8List bytes, [int start = 0, int? end]) {
  final last = end ?? bytes.length;
  var crc = 0xFFFF;
  for (var i = start; i < last; i++) {
    crc ^= bytes[i] << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// Encodes [TelemetryFrame]s to and from raw payload bytes.
abstract final class FrameCodec {
  /// Serializes [frame] into a complete payload (CRC appended).
  ///
  /// Continuous fields are quantized to their wire fixed-point scales; values
  /// outside the representable range are clamped rather than wrapped (roll
  /// wraps at ±327.67°, latitudes at the poles, longitudes at ±180°, heading
  /// modulo 360°).
  static Uint8List encode(TelemetryFrame frame) {
    final b = ByteData(TelemetryFraming.payloadLength);

    b.setUint8(TelemetryLayout.offsetFlags, frame.flags);
    b.setUint16(TelemetryLayout.offsetSeq, _clampU16(frame.sequence));
    b.setInt32(
      TelemetryLayout.offsetGpsLat,
      _clampI32((frame.latitude.clamp(-90.0, 90.0) / TelemetryLayout.latLonScale).round()),
    );
    b.setInt32(
      TelemetryLayout.offsetGpsLon,
      _clampI32((frame.longitude.clamp(-180.0, 180.0) / TelemetryLayout.latLonScale).round()),
    );
    b.setInt32(
      TelemetryLayout.offsetGpsAlt,
      _clampI32((frame.baroAltitude * 100).round()),
    );
    b.setInt32(
      TelemetryLayout.offsetBaroAlt,
      _clampI32((frame.baroAltitude * 100).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetVelN,
      _clampI16((frame.velocityNorth / TelemetryLayout.velocityScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetVelE,
      _clampI16((frame.velocityEast / TelemetryLayout.velocityScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetVelD,
      _clampI16((-frame.velocityUp / TelemetryLayout.velocityScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetAccelX,
      _clampI16((frame.accelX / TelemetryLayout.accelScaleMg).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetAccelY,
      _clampI16((frame.accelY / TelemetryLayout.accelScaleMg).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetAccelZ,
      _clampI16((frame.accelZ / TelemetryLayout.accelScaleMg).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetGyroX,
      _clampI16((frame.gyroX / TelemetryLayout.gyroScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetGyroY,
      _clampI16((frame.gyroY / TelemetryLayout.gyroScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetGyroZ,
      _clampI16((frame.gyroZ / TelemetryLayout.gyroScale).round()),
    );
    b.setUint16(
      TelemetryLayout.offsetHeading,
      _clampU16((((frame.heading % 360) + 360) % 360 / TelemetryLayout.angleScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetRoll,
      _clampI16((frame.roll / TelemetryLayout.angleScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetPitch,
      _clampI16((frame.pitch / TelemetryLayout.angleScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetYaw,
      _clampI16((frame.yaw / TelemetryLayout.angleScale).round()),
    );
    b.setUint16(
      TelemetryLayout.offsetBattery,
      _clampU16((frame.batteryVoltage * 1000).round()),
    );
    b.setUint16(TelemetryLayout.offsetHall, _clampU16(frame.hallRaw));
    b.setUint8(TelemetryLayout.offsetFsmState, frame.fsmStateId);

    final bytes = b.buffer.asUint8List();
    final crc = crc16CCITT(bytes, 0, payloadCrcOffset);
    b.setUint16(payloadCrcOffset, crc);
    return bytes;
  }

  /// Builds a complete wire packet (sync word + payload) for [frame].
  static Uint8List encodePacket(TelemetryFrame frame) {
    final payload = encode(frame);
    final packet = Uint8List(TelemetryFraming.totalPacketLength);
    packet[0] = TelemetryFraming.startByte0;
    packet[1] = TelemetryFraming.startByte1;
    packet.setAll(TelemetryFraming.startWordLength, payload);
    return packet;
  }

  /// Decodes a raw payload (as carried by a [TelemetryPacket]) into a frame.
  ///
  /// Returns `null` for wrong lengths or CRC mismatches.
  static TelemetryFrame? decode(Uint8List payload, {required int receivedAtMs}) {
    if (payload.length != TelemetryFraming.payloadLength) return null;
    final b = ByteData.sublistView(payload);
    if (b.getUint16(payloadCrcOffset) !=
        crc16CCITT(payload, 0, payloadCrcOffset)) {
      return null;
    }
    return _buildFrame(
        b, receivedAtMs, b.getUint8(TelemetryLayout.offsetFsmState));
  }

  static TelemetryFrame? _buildFrame(
      ByteData b, int receivedAtMs, int fsmStateId) {
    final lat =
        b.getInt32(TelemetryLayout.offsetGpsLat) * TelemetryLayout.latLonScale;
    if (lat.isNaN) return null;

    return TelemetryFrame(
      receivedAtMs: receivedAtMs,
      flags: b.getUint8(TelemetryLayout.offsetFlags),
      sequence: b.getUint16(TelemetryLayout.offsetSeq),
      latitude: lat,
      longitude: b.getInt32(TelemetryLayout.offsetGpsLon) * TelemetryLayout.latLonScale,
      baroAltitude: b.getInt32(TelemetryLayout.offsetBaroAlt) / 100,
      velocityNorth:
          b.getInt16(TelemetryLayout.offsetVelN) * TelemetryLayout.velocityScale,
      velocityEast:
          b.getInt16(TelemetryLayout.offsetVelE) * TelemetryLayout.velocityScale,
      velocityUp:
          -b.getInt16(TelemetryLayout.offsetVelD) * TelemetryLayout.velocityScale,
      accelX: b.getInt16(TelemetryLayout.offsetAccelX) * TelemetryLayout.accelScaleMg,
      accelY: b.getInt16(TelemetryLayout.offsetAccelY) * TelemetryLayout.accelScaleMg,
      accelZ: b.getInt16(TelemetryLayout.offsetAccelZ) * TelemetryLayout.accelScaleMg,
      gyroX: b.getInt16(TelemetryLayout.offsetGyroX) * TelemetryLayout.gyroScale,
      gyroY: b.getInt16(TelemetryLayout.offsetGyroY) * TelemetryLayout.gyroScale,
      gyroZ: b.getInt16(TelemetryLayout.offsetGyroZ) * TelemetryLayout.gyroScale,
      heading: b.getUint16(TelemetryLayout.offsetHeading) * TelemetryLayout.angleScale,
      roll: b.getInt16(TelemetryLayout.offsetRoll) * TelemetryLayout.angleScale,
      pitch: b.getInt16(TelemetryLayout.offsetPitch) * TelemetryLayout.angleScale,
      yaw: b.getInt16(TelemetryLayout.offsetYaw) * TelemetryLayout.angleScale,
      batteryVoltage: b.getUint16(TelemetryLayout.offsetBattery) / 1000,
      hallRaw: b.getUint16(TelemetryLayout.offsetHall),
      fsmStateId: fsmStateId,
    );
  }

  /// Verifies the trailing CRC of a raw payload without fully decoding it.
  static bool verifyCrc(Uint8List payload) {
    if (payload.length != TelemetryFraming.payloadLength) return false;
    final b = ByteData.sublistView(payload);
    return b.getUint16(payloadCrcOffset) ==
        crc16CCITT(payload, 0, payloadCrcOffset);
  }

  static int _clampI16(int v) => v.clamp(-0x8000, 0x7FFF);
  static int _clampU16(int v) => v.clamp(0, 0xFFFF);
  static int _clampI32(int v) => v.clamp(-0x80000000, 0x7FFFFFFF);
}
