import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('segfault demo connector registry', () {
    test('is listed alongside mock + segfault, mock stays default', () {
      expect(
        allConnectors.map((c) => c.id),
        containsAll(['mock', 'segfault', 'segfault_demo']),
      );
      expect(defaultConnectorId, 'mock');
      expect(connectorById('segfault_demo'), same(segfaultDemoConnector));
      expect(isKnownConnectorId('segfault_demo'), isTrue);
      expect(
        visibleConnectors.map((c) => c.id),
        containsAll(['segfault', 'segfault_demo']),
      );
    });
  });

  group('segfault demo connector', () {
    test('publishes the 2x2 demo FSM with pipeline flags + colors', () {
      final states = segfaultDemoConnector.states;
      expect([for (final s in states) s.id], [0, 1, 2, 3, 255]);
      expect(
        [for (final s in states.where((s) => s.pipeline)) s.id],
        [0, 1, 2, 3],
      );
      for (final s in states) {
        expect(s.label, isNotEmpty);
        expect(s.colorArgb & 0xFF000000, 0xFF000000);
      }
      expect(segfaultDemoConnector.stateForId(0).label, 'Realtime Locked');
      expect(segfaultDemoConnector.stateForId(1).label, 'Realtime Deployed');
      expect(segfaultDemoConnector.stateForId(2).label, 'Powersaver Locked');
      expect(segfaultDemoConnector.stateForId(3).label, 'Powersaver Deployed');
      // Locked variants keep the nosecone; deployed variants open the chute.
      expect(segfaultDemoConnector.stateForId(0).hasNosecone, isTrue);
      expect(segfaultDemoConnector.stateForId(2).hasNosecone, isTrue);
      expect(segfaultDemoConnector.stateForId(1).hasNosecone, isFalse);
      expect(segfaultDemoConnector.stateForId(3).hasNosecone, isFalse);
      expect(segfaultDemoConnector.stateForId(1).showsParachute, isTrue);
      expect(segfaultDemoConnector.stateForId(3).showsParachute, isTrue);
      expect(segfaultDemoConnector.stateForId(1).hasParachute, isTrue);
      expect(segfaultDemoConnector.stateForId(3).hasParachute, isTrue);
      expect(segfaultDemoConnector.stateForId(0).hasParachute, isFalse);
      expect(segfaultDemoConnector.stateForId(2).showsParachute, isFalse);
      expect(segfaultDemoConnector.stateForId(0x42).id, 255);
      expect(segfaultDemoConnector.stateForId(4).id, 255);
      expect(segfaultDemoConnector.unknownStateId, 255);
    });

    test('publishes chute + rate commands + state-request bytes', () {
      expect(segfaultDemoConnector.commands.map((c) => c.id), [
        'stow_parachute',
        'deploy_parachute',
        'realtime',
        'powersaver',
      ]);
      expect(segfaultDemoConnector.bytesForState(0), [0x47, 0x43, 0x01, 0x00]);
      expect(segfaultDemoConnector.bytesForState(3), [0x47, 0x43, 0x01, 0x03]);
      expect(segfaultDemoConnector.bytesForState(4), isNull);
      expect(segfaultDemoConnector.bytesForState(255), isNull);

      expect(
        segfaultDemoConnector.describeCommand([0x47, 0x43, 0xAA, 0x00]).label,
        'Deploy chute',
      );
      expect(
        segfaultDemoConnector.describeCommand([0x47, 0x43, 0x55, 0x00]).label,
        'Lock chute',
      );
      expect(
        segfaultDemoConnector.describeCommand([0x47, 0x43, 0x52, 0x00]).label,
        'Realtime',
      );
      expect(
        segfaultDemoConnector.describeCommand([0x47, 0x43, 0x50, 0x00]).label,
        'Powersaver',
      );
      expect(
        segfaultDemoConnector.describeCommand([0x47, 0x43, 0x01, 0x02]).label,
        'Set Powersaver Locked',
      );
      expect(
        segfaultDemoConnector.describeCommand([0x00, 0x01, 0x02, 0x03]).label,
        'Unknown command',
      );
      // Full-firmware baseline reset is not part of the demo uplink.
      expect(
        segfaultDemoConnector.describeCommand([0x47, 0x43, 0x67, 0x67]).label,
        'Unknown command',
      );
    });

    test('has no flight events (no autonomous detection)', () {
      expect(segfaultDemoConnector.events, isEmpty);
    });

    test('populates everything except GPS position and horizontal velocity', () {
      for (final field in TelemetryField.values) {
        final supported = segfaultDemoConnector.capabilities.supports(field);
        if (field == TelemetryField.gpsPosition ||
            field == TelemetryField.velocityHorizontal) {
          expect(supported, isFalse, reason: field.name);
        } else {
          expect(supported, isTrue, reason: field.name);
        }
      }
    });

    test('shares the OG wire but reports no GPS fix', () {
      final packet = SegfaultPacketCodec.encodePacket(
        packetId: 9,
        stateFlags: 1,
        accelXMps2: 0,
        accelYMps2: 0,
        accelZMps2: 9.80665,
        aglM: 42.0,
        batteryV: 4.0,
        verticalUpMps: 1.5,
        ky024: 1500,
      );
      expect(packet.length, 33);
      expect(packet[0], 0xA5);
      expect(packet[1], 0x5A);

      final parser = segfaultDemoConnector.createParser();
      final frames = parser.feed(packet, timestampMs: 777);
      expect(frames, hasLength(1));
      final f = frames.single;
      expect(f.sequence, 9);
      expect(f.fsmStateId, 1);
      expect(f.receivedAtMs, 777);
      expect(f.baroAltitude, closeTo(42.0, 0.06));
      expect(f.velocityUp, closeTo(1.5, 0.06));
      // Zero GPS offsets decode to the base position, but with no fix.
      expect(f.latitude, closeTo(SegfaultPacketCodec.baseLatitudeDeg, 1e-9));
      expect(f.longitude, closeTo(SegfaultPacketCodec.baseLongitudeDeg, 1e-9));
      expect(f.gpsHasFix, isFalse);
      expect(parser.matchedPackets, 1);
      expect(parser.matchedBytes, 33);
    });

    test('parser hunts sync, tolerates splits and garbage', () {
      final parser = segfaultDemoConnector.createParser();
      final a = SegfaultPacketCodec.encodePacket(packetId: 1, stateFlags: 0);
      final b = SegfaultPacketCodec.encodePacket(packetId: 2, stateFlags: 3);

      var frames = parser.feed(
        Uint8List.fromList([0x00, 0xFF, ...a]),
        timestampMs: 1,
      );
      expect(frames, hasLength(1));
      expect(frames.single.sequence, 1);
      expect(frames.single.gpsHasFix, isFalse);
      expect(parser.garbageBytes, 2);

      parser.resetStats();
      expect(parser.feed(a.sublist(0, 10), timestampMs: 2), isEmpty);
      frames = parser.feed(a.sublist(10), timestampMs: 2);
      expect(frames, hasLength(1));
      expect(frames.single.sequence, 1);

      parser.resetStats();
      frames = parser.feed(Uint8List.fromList([...a, ...b]), timestampMs: 3);
      expect(frames, hasLength(2));
      expect([frames[0].sequence, frames[1].sequence], [1, 2]);
      expect([frames[0].fsmStateId, frames[1].fsmStateId], [0, 3]);
      expect(parser.matchedPackets, 2);
      expect(parser.matchedBytes, 66);
    });
  });
}
