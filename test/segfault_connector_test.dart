import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('segfault connector registry', () {
    test('is listed alongside mock, mock stays default', () {
      expect(allConnectors.map((c) => c.id), containsAll(['mock', 'segfault']));
      expect(defaultConnectorId, 'mock');
      expect(connectorById('segfault'), same(segfaultConnector));
      expect(isKnownConnectorId('segfault'), isTrue);
    });
  });

  group('segfault connector', () {
    test('publishes the 5-state FSM with pipeline flags + colors', () {
      final states = segfaultConnector.states;
      expect([for (final s in states) s.id], [0, 1, 2, 3, 4, 255]);
      expect(
        [for (final s in states.where((s) => s.pipeline)) s.id],
        [0, 1, 2, 3, 4],
      );
      for (final s in states) {
        expect(s.label, isNotEmpty);
        expect(s.colorArgb & 0xFF000000, 0xFF000000);
      }
      expect(segfaultConnector.stateForId(0).label, 'Before Launch');
      expect(segfaultConnector.stateForId(1).hasNosecone, isTrue);
      expect(segfaultConnector.stateForId(2).hasNosecone, isTrue);
      expect(segfaultConnector.stateForId(3).hasNosecone, isFalse);
      expect(segfaultConnector.stateForId(4).showsParachute, isTrue);
      expect(segfaultConnector.stateForId(4).hasParachute, isTrue);
      expect(segfaultConnector.stateForId(3).hasParachute, isFalse);
      expect(segfaultConnector.stateForId(0x42).id, 255);
      expect(segfaultConnector.unknownStateId, 255);
      // Pre-launch states sit on the pad in 3D views.
      expect(
        [for (final s in states.where((s) => s.grounded)) s.id],
        [0, 1],
      );
    });

    test('publishes commands + state-request bytes + descriptions', () {
      expect(segfaultConnector.commands.map((c) => c.id), [
        'deploy_parachute',
        'stow_parachute',
        'reset_baseline',
      ]);
      expect(segfaultConnector.bytesForState(2),
          [0x47, 0x43, 0x01, 0x02]);
      expect(segfaultConnector.bytesForState(4),
          [0x47, 0x43, 0x01, 0x04]);
      expect(segfaultConnector.bytesForState(5), isNull);
      expect(segfaultConnector.bytesForState(255), isNull);

      expect(
        segfaultConnector
            .describeCommand([0x47, 0x43, 0xAA, 0x00])
            .label,
        'Deploy chute',
      );
      expect(
        segfaultConnector.describeCommand([0x47, 0x43, 0x01, 0x02]).label,
        'Set Flight',
      );
      expect(
        segfaultConnector.describeCommand([0x00, 0x01, 0x02, 0x03]).label,
        'Unknown command',
      );
    });

    test('publishes launch/apogee/parachute events', () {
      String show(ConnectorEventDef e) =>
          '${e.label} ${e.fromStateId}->${e.toStateId}'
          '${[
            for (final t in e.additionalTransitions)
              ' +${t.fromStateId}->${t.toStateId}'
          ].join()}';
      expect(
        [for (final e in segfaultConnector.events) show(e)],
        [
          'Launch 1->2',
          'Apogee 2->3 +2->4',
          'Parachute 3->4',
        ],
      );
    });

    test('populates everything except horizontal velocity', () {
      for (final field in TelemetryField.values) {
        final supported = segfaultConnector.capabilities.supports(field);
        if (field == TelemetryField.velocityHorizontal) {
          expect(supported, isFalse, reason: field.name);
        } else {
          expect(supported, isTrue, reason: field.name);
        }
      }
    });

    test('decodes scales like the OG firmware', () {
      final packet = SegfaultPacketCodec.encodePacket(
        packetId: 42,
        stateFlags: 2,
        accelXMps2: 0,
        accelYMps2: 0,
        accelZMps2: 9.80665,
        gyroXDps: 10.0,
        aglM: 123.4,
        batteryV: 4.2,
        latitude: SegfaultPacketCodec.baseLatitudeDeg + 0.001,
        longitude: SegfaultPacketCodec.baseLongitudeDeg - 0.002,
        verticalUpMps: 12.3,
        ky024: 2048,
      );
      expect(packet.length, 33);
      // Wire order is LE A5 5A.
      expect(packet[0], 0xA5);
      expect(packet[1], 0x5A);

      final parser = segfaultConnector.createParser();
      final frames = parser.feed(packet, timestampMs: 999);
      expect(frames, hasLength(1));
      final f = frames.single;
      expect(f.sequence, 42);
      expect(f.fsmStateId, 2);
      expect(f.receivedAtMs, 999);
      expect(f.baroAltitude, closeTo(123.4, 0.06));
      expect(f.velocityUp, closeTo(12.3, 0.06));
      expect(f.velocityNorth, 0);
      expect(f.velocityEast, 0);
      expect(f.accelZ, closeTo(9.80665, 0.01));
      expect(f.gyroX, closeTo(10.0, 0.05));
      expect(f.latitude,
          closeTo(SegfaultPacketCodec.baseLatitudeDeg + 0.001, 1e-6));
      expect(f.longitude,
          closeTo(SegfaultPacketCodec.baseLongitudeDeg - 0.002, 1e-6));
      expect(f.batteryVoltage, closeTo(4.2, 0.011));
      expect(f.hallRaw, 2048);
      expect(f.gpsHasFix, isTrue);
      // Upright 1g: roll/pitch ~0.
      expect(f.roll, closeTo(0, 0.5));
      expect(f.pitch, closeTo(0, 0.5));
      expect(parser.matchedPackets, 1);
      expect(parser.matchedBytes, 33);
      expect(parser.crcErrorCount, 0);
    });

    test('flight-frame translation round-trips within wire quantum', () {
      // Representative mid-flight values: encode like
      // tool/translate_connector.dart does, decode back, compare.
      final packet = SegfaultPacketCodec.encodePacket(
        packetId: 300, // wraps u8, like a long flight
        stateFlags: 4,
        accelXMps2: 1.657,
        accelYMps2: 9.542,
        accelZMps2: 0.776,
        gyroXDps: 4.45,
        gyroYDps: -19.09,
        gyroZDps: 2.44,
        aglM: 320.4,
        batteryV: 4.0,
        latitude: 49.797,
        longitude: 16.697,
        verticalUpMps: 11.5,
        ky024: 2154,
      );
      final frame = SegfaultPacketCodec.decode(packet, receivedAtMs: 7)!;
      expect(frame.sequence, 300 & 0xFF);
      expect(frame.fsmStateId, 4);
      expect(frame.baroAltitude, closeTo(320.4, 0.06));
      expect(frame.velocityUp, closeTo(11.5, 0.06));
      expect(frame.accelX, closeTo(1.657, 0.01));
      expect(frame.gyroY, closeTo(-19.09, 0.05));
      expect(frame.batteryVoltage, closeTo(4.0, 0.011));
      expect(frame.hallRaw, 2154);
      expect(frame.latitude, closeTo(49.797, 1.2e-5));
      // Dropped without replacement: horizontal velocity, yaw/heading.
      // Roll/pitch re-derive from accel.
      expect(frame.velocityNorth, 0);
      expect(frame.yaw, 0);
      expect(frame.heading, 0);
    });

    test('parser hunts sync, tolerates splits and garbage', () {
      final parser = segfaultConnector.createParser();
      final a = SegfaultPacketCodec.encodePacket(packetId: 1, stateFlags: 0);
      final b = SegfaultPacketCodec.encodePacket(packetId: 2, stateFlags: 1);

      // Garbage prefix is skipped.
      var frames = parser.feed(
          Uint8List.fromList([0x00, 0xFF, ...a]), timestampMs: 1);
      expect(frames, hasLength(1));
      expect(frames.single.sequence, 1);
      expect(parser.garbageBytes, 2);

      // Split sync across chunks still frames.
      parser.resetStats();
      expect(parser.feed(a.sublist(0, 10), timestampMs: 2), isEmpty);
      frames = parser.feed(a.sublist(10), timestampMs: 2);
      expect(frames, hasLength(1));
      expect(frames.single.sequence, 1);

      // Two packets in one chunk.
      parser.resetStats();
      frames = parser.feed(Uint8List.fromList([...a, ...b]), timestampMs: 3);
      expect(frames, hasLength(2));
      expect([frames[0].sequence, frames[1].sequence], [1, 2]);
      expect(parser.matchedPackets, 2);
      expect(parser.matchedBytes, 66);
    });
  });
}
