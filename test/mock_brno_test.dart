import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('Brno static port', () {
    test('port name is distinct from the other mock ports', () {
      expect(MockBrnoSerialPort.portName, 'Brno');
      expect(MockBrnoSerialPort.portName, isNot(MockSerialPort.portName));
      expect(MockBrnoSerialPort.portName, isNot(MockBqSerialPort.portName));
      expect(MockBrnoSerialPort.portName, isNot(MockDcSerialPort.portName));
      expect(SerialService.isMockPortName(MockBrnoSerialPort.portName), isTrue);
    });

    test('listed alongside the other mock ports in dev builds', () {
      expect(
        SerialService.availablePorts,
        contains(MockBrnoSerialPort.portName),
      );
    });

    test('toggle helper flips parachute every 5 s (@10 Hz)', () {
      for (var tick = 0; tick < mockBrnoToggleTicks; tick++) {
        expect(mockBrnoParachuteForTick(tick), isFalse, reason: 'tick $tick');
      }
      for (var tick = mockBrnoToggleTicks; tick < mockBrnoPeriodTicks; tick++) {
        expect(mockBrnoParachuteForTick(tick), isTrue, reason: 'tick $tick');
      }
      expect(mockBrnoParachuteForTick(mockBrnoPeriodTicks), isFalse);
      expect(mockBrnoPeriodTicks, 100);
    });

    test('emits static frames with toggling parachute state', () {
      FakeAsync().run((async) {
        final port = MockBrnoSerialPort();
        addTearDown(port.disconnect);
        final chunks = <Uint8List>[];
        final sub = port.byteStream.listen(chunks.add);
        expect(port.connect(), isTrue);
        expect(port.isConnected, isTrue);

        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(chunks.length, greaterThanOrEqualTo(100));

        final parser = MockConnectorParser();
        final frames = <TelemetryFrame>[];
        for (final chunk in chunks) {
          frames.addAll(parser.feed(chunk));
        }
        expect(frames.length, chunks.length);

        for (final frame in frames) {
          expect(
            (frame.latitude - 49.22892339423079) * mockBrnoMetersPerDegLat,
            closeTo(3, 0.02),
          );
          expect(frame.longitude, closeTo(16.582853748863815, 1e-7));
          expect(frame.baroAltitude, closeTo(18, 1e-9));
          expect(frame.velocityNorth, 0);
          expect(frame.velocityEast, 0);
          expect(frame.velocityUp, 0);
          expect(frame.speedTotal, 0);
          expect(frame.gpsHasFix, isTrue);
        }

        // Sequences advance one step per frame.
        for (var i = 1; i < frames.length; i++) {
          expect(frames[i].sequence, frames[i - 1].sequence + 1);
        }

        // First 5 s idle (parachute off), next 5 s parachute (on).
        expect(frames[0].fsmStateId, FsmState.idle.id);
        expect(frames[0].fsmState.hasParachute, isFalse);
        expect(frames[mockBrnoToggleTicks].fsmStateId, FsmState.parachute.id);
        expect(frames[mockBrnoToggleTicks].fsmState.hasParachute, isTrue);
        expect(frames[mockBrnoPeriodTicks].fsmStateId, FsmState.idle.id);

        port.disconnect();
        expect(port.isConnected, isFalse);
        sub.cancel();
      });
    });

    test('move commands shift the reported position by 1 m', () {
      FakeAsync().run((async) {
        final port = MockBrnoSerialPort();
        addTearDown(port.disconnect);
        final chunks = <Uint8List>[];
        final sub = port.byteStream.listen(chunks.add);
        expect(port.connect(), isTrue);

        Uint8List cmd(int third) =>
            Uint8List.fromList([0x54, 0x43, third, 0x00]);

        expect(port.sendBytes(cmd(mockBrnoMoveUpCmd)), isTrue);
        expect(port.sendBytes(cmd(mockBrnoMoveEastCmd)), isTrue);
        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();

        final parser = MockConnectorParser();
        final frames = <TelemetryFrame>[];
        for (final chunk in chunks) {
          frames.addAll(parser.feed(chunk));
        }
        expect(frames, isNotEmpty);
        final last = frames.last;
        expect(last.baroAltitude, closeTo(19, 1e-9));
        expect(last.latitude, closeTo(mockBrnoLatitude, 1e-7));
        // 1 m east at Brno latitude (~49.2° N).
        expect(last.longitude, greaterThan(mockBrnoLongitude));
        expect(last.longitude - mockBrnoLongitude, closeTo(1.38e-5, 0.5e-5));
        expect(last.fsmStateId, FsmState.idle.id);

        chunks.clear();
        expect(port.sendBytes(cmd(mockBrnoMoveDownCmd)), isTrue);
        expect(port.sendBytes(cmd(mockBrnoMoveWestCmd)), isTrue);
        async.elapse(const Duration(milliseconds: 200));
        async.flushMicrotasks();

        final back = <TelemetryFrame>[];
        for (final chunk in chunks) {
          back.addAll(parser.feed(chunk));
        }
        expect(back, isNotEmpty);
        expect(back.last.baroAltitude, closeTo(18, 1e-9));
        expect(back.last.longitude, closeTo(mockBrnoLongitude, 1e-7));

        port.disconnect();
        sub.cancel();
      });
    });

    test('sendBytes acks only while connected', () {
      final port = MockBrnoSerialPort();
      addTearDown(port.disconnect);
      expect(
        port.sendBytes(Uint8List.fromList([0x54, 0x43, 0x10, 0x00])),
        isFalse,
      );
      expect(port.connect(), isTrue);
      expect(
        port.sendBytes(Uint8List.fromList([0x54, 0x43, 0x10, 0x00])),
        isTrue,
      );
      port.disconnect();
      expect(
        port.sendBytes(Uint8List.fromList([0x54, 0x43, 0x10, 0x00])),
        isFalse,
      );
    });

    test('SerialService routes Brno as a mock', () {
      final service = SerialService();
      addTearDown(service.disconnect);
      expect(service.connect(MockBrnoSerialPort.portName), isTrue);
      expect(service.isConnected, isTrue);
      expect(
        service.sendBytes(Uint8List.fromList([0x54, 0x43, 0x10, 0x00])),
        isTrue,
      );
      service.disconnect();
      expect(service.isConnected, isFalse);
    });
  });

  group('Brno connector', () {
    test('owns four 1 m move commands and no state requests', () {
      expect(brnoConnector.id, 'brno');
      expect(
        [for (final c in brnoConnector.commands) c.id],
        ['move_up', 'move_down', 'move_west', 'move_east'],
      );
      for (final cmd in brnoConnector.commands) {
        expect(cmd.bytes.length, 4);
        expect(cmd.bytes[0], 0x54);
        expect(cmd.bytes[1], 0x43);
      }
      expect(brnoConnector.bytesForState(FsmState.idle.id), isNull);
      expect(brnoConnector.events, isEmpty);
      expect(
        brnoConnector.describeCommand([0x54, 0x43, 0x10, 0x00]).label,
        'Up 1 m',
      );
      expect(
        brnoConnector.describeCommand([0x54, 0x43, 0x13, 0x00]).label,
        'West 1 m',
      );
      expect(
        brnoConnector.describeCommand([0x54, 0x43, 0x09, 0x00]).label,
        'Unknown command',
      );
    });

    test('move bytes drive the Brno port', () {
      final port = MockBrnoSerialPort();
      addTearDown(port.disconnect);
      expect(port.connect(), isTrue);
      for (final cmd in brnoConnector.commands) {
        expect(port.sendBytes(Uint8List.fromList(cmd.bytes)), isTrue);
      }
    });
  });
}
