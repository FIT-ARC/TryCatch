import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('connector registry', () {
    test('lists the mock connector as the default', () {
      expect(allConnectors, isNotEmpty);
      expect(allConnectors.map((c) => c.id), contains('mock'));
      expect(defaultConnectorId, 'mock');
      expect(connectorById('mock'), same(mockConnector));
      expect(connectorById('nope'), isNull);
      expect(isKnownConnectorId('mock'), isTrue);
      expect(isKnownConnectorId('nope'), isFalse);
    });
  });

  group('mock connector', () {
    test('publishes the full FSM with pipeline flags + colors', () {
      final states = mockConnector.states;
      expect(
        [for (final s in states) s.id],
        [0, 1, 2, 3, 4, 5, 6, 7, 255],
      );
      expect(
        [for (final s in states.where((s) => s.pipeline)) s.id],
        [0, 1, 2, 3, 4, 5],
      );
      for (final s in states) {
        expect(s.label, isNotEmpty);
        expect(s.colorArgb & 0xFF000000, 0xFF000000);
      }
      // Airframe flags match the legacy FsmState table.
      expect(mockConnector.stateForId(1).hasNosecone, isTrue);
      expect(mockConnector.stateForId(3).hasNosecone, isFalse);
      expect(mockConnector.stateForId(4).showsParachute, isTrue);
      expect(mockConnector.stateForId(5).showsParachute, isFalse);
      expect(mockConnector.stateForId(5).hasParachute, isTrue);
      // Pad/landed states are grounded for pad-height rendering.
      expect(
        [for (final s in states.where((s) => s.grounded)) s.id],
        [0, 1, 5],
      );
      // Unmapped ids fall back to unknown.
      expect(mockConnector.stateForId(0x42).id, 255);
      expect(mockConnector.unknownStateId, 255);
      // Chips hide the unknown fallback but the readout still resolves it.
      final chips = [
        for (final s in mockConnector.states)
          if (s.id != mockConnector.unknownStateId) s,
      ];
      expect(chips.map((s) => s.id), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(mockConnector.stateForId(0x42).label, 'Unknown');
    });

    test('publishes the command catalog + state-request bytes', () {
      expect(mockConnector.commands.map((c) => c.id),
          ['arm', 'disarm', 'fire_parachute', 'beep', 'reset_fsm']);
      expect(mockConnector.bytesForState(2), [0x54, 0x43, 0x07, 0x02]);
      expect(mockConnector.bytesForState(0x42), isNull);
    });

    test('publishes the nominal flight events', () {
      String show(ConnectorEventDef e) =>
          '${e.label} ${e.fromStateId}->${e.toStateId}'
          '${[
            for (final t in e.additionalTransitions)
              ' +${t.fromStateId}->${t.toStateId}'
          ].join()}';
      expect(
        [for (final e in mockConnector.events) show(e)],
        [
          'Launch 1->2',
          'Apogee 2->3 +2->4',
          'Parachute 3->4',
          'Touchdown 4->5',
        ],
      );
    });

    test('populates the whole internal frame', () {
      for (final field in TelemetryField.values) {
        expect(mockConnector.capabilities.supports(field), isTrue,
            reason: field.name);
      }
    });

    test('parser converts the bytestream to internal frames', () {
      final parser = mockConnector.createParser();
      final packet = FrameCodec.encodePacket(TelemetryFrame(
        sequence: 7,
        flags: FrameFlags.gpsFix | FrameFlags.gpsFix3d,
        latitude: 50.0,
        longitude: 14.0,
        baroAltitude: 123,
        fsmStateId: 2,
      ));
      final frames = parser.feed(packet, timestampMs: 123456);
      expect(frames, hasLength(1));
      expect(frames.single.sequence, 7);
      expect(frames.single.baroAltitude, closeTo(123, 0.01));
      expect(frames.single.fsmStateId, 2);
      expect(frames.single.receivedAtMs, 123456);
      expect(parser.matchedPackets, 1);

      // Garbage + corrupt frames are dropped, counters track them.
      parser.resetStats();
      final corrupt = Uint8List.fromList(packet)..[10] ^= 0xFF;
      expect(parser.feed(Uint8List.fromList([0x00, 0x01, 0x02])), isEmpty);
      expect(parser.feed(corrupt), isEmpty);
      expect(parser.garbageBytes, greaterThan(0));
      expect(parser.crcErrorCount, 1);
    });
  });
}
