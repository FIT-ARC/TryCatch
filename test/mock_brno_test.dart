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
          expect(frame.latitude, closeTo(49.22892339423079, 1e-7));
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

    test('sendBytes acks only while connected', () {
      final port = MockBrnoSerialPort();
      addTearDown(port.disconnect);
      expect(
        port.sendBytes(Uint8List.fromList([0x54, 0x43, 0x01, 0x00])),
        isFalse,
      );
      expect(port.connect(), isTrue);
      expect(
        port.sendBytes(Uint8List.fromList([0x54, 0x43, 0x01, 0x00])),
        isTrue,
      );
      port.disconnect();
      expect(
        port.sendBytes(Uint8List.fromList([0x54, 0x43, 0x01, 0x00])),
        isFalse,
      );
    });

    test('SerialService routes Brno as a mock', () {
      final service = SerialService();
      addTearDown(service.disconnect);
      expect(service.connect(MockBrnoSerialPort.portName), isTrue);
      expect(service.isConnected, isTrue);
      expect(
        service.sendBytes(Uint8List.fromList([0x54, 0x43, 0x05, 0x00])),
        isTrue,
      );
      service.disconnect();
      expect(service.isConnected, isFalse);
    });
  });
}
