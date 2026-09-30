import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/services/live_bridge/bridge_schema.dart';

/// Every value must be a JSON primitive so the packet crosses the
/// isolate boundary by value.
bool _isTransferable(dynamic value) {
  if (value == null || value is num || value is String || value is bool) {
    return true;
  }
  if (value is Map) {
    return value.keys.every((k) => k is String) &&
        value.values.every(_isTransferable);
  }
  if (value is List) return value.every(_isTransferable);
  return false;
}

void main() {
  group('LiveBridgeSchema packet', () {
    test('carries exactly the seven public fields', () {
      final packet = LiveBridgeSchema.packet(
        frame: const TelemetryFrame(
          receivedAtMs: 1700000000000,
          latitude: 50.0755,
          longitude: 14.4378,
          baroAltitude: 812.34,
          velocityNorth: 3.0,
          velocityEast: 4.0,
          velocityUp: 0.0,
          fsmStateId: 4,
        ),
        siteMslM: 403,
        maxAltitudeAglM: 900.0,
        hasParachute: true,
      );
      expect(
        packet.keys.toSet(),
        {
          'receivedAt',
          'gpsLat',
          'gpsLong',
          'altitudeMSL',
          'hasParachute',
          'maxAltitude',
          'totalVelocity',
        },
      );
      expect(packet['receivedAt'], 1700000000000);
      expect(packet['gpsLat'], 50.0755);
      expect(packet['gpsLong'], 14.4378);
      expect(packet['altitudeMSL'], closeTo(403 + 812.34, 1e-9));
      expect(packet['hasParachute'], true);
      expect(packet['maxAltitude'], closeTo(403 + 900.0, 1e-9));
      expect(packet['totalVelocity'], closeTo(5.0, 1e-9));
    });

    test('is JSON-encodable with primitives only', () {
      final packet = LiveBridgeSchema.packet(
        frame: const TelemetryFrame(),
        siteMslM: 0,
        maxAltitudeAglM: 0,
        hasParachute: false,
      );
      expect(_isTransferable(packet), true);
      expect(() => jsonEncode(packet), returnsNormally);
    });
  });
}
