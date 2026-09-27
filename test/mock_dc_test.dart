import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

/// Deterministic chaos: every rate pinned to 0.0 (never) or 1.0 (always).
MockDcSerialPort _port({
  double connectFailureRate = 0.0,
  double dropPerTick = 0.0,
  double sendFailureRate = 0.0,
}) =>
    MockDcSerialPort(
      connectFailureRate: connectFailureRate,
      dropPerTick: dropPerTick,
      sendFailureRate: sendFailureRate,
    );

void main() {
  group('MOCK-DC chaos port', () {
    test('port name is distinct from MOCK and MOCK-BQ', () {
      expect(MockDcSerialPort.portName, 'MOCK-DC');
      expect(MockDcSerialPort.portName, isNot(MockSerialPort.portName));
      expect(MockDcSerialPort.portName, isNot(MockBqSerialPort.portName));
      expect(
        SerialService.isMockPortName(MockDcSerialPort.portName),
        isTrue,
      );
    });

    test('listed alongside the other mock ports in dev builds', () {
      expect(
        SerialService.availablePorts,
        contains(MockDcSerialPort.portName),
      );
    });

    test('default rates are sane probabilities', () {
      final port = MockDcSerialPort();
      addTearDown(port.disconnect);
      for (final rate in [
        port.connectFailureRate,
        port.dropPerTick,
        port.sendFailureRate,
      ]) {
        expect(rate, greaterThanOrEqualTo(0));
        expect(rate, lessThanOrEqualTo(1));
      }
      // Chaos, not carnage: opens usually succeed, links live a while.
      expect(port.connectFailureRate, lessThan(0.5));
      expect(port.dropPerTick, lessThan(0.05));
    });

    test('refused open stays fully down', () {
      FakeAsync().run((async) {
        final port = _port(connectFailureRate: 1.0);
        final chunks = <Uint8List>[];
        final sub = port.byteStream.listen(chunks.add);
        expect(port.connect(), isFalse);
        expect(port.isConnected, isFalse);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(chunks, isEmpty);
        expect(port.isConnected, isFalse);
        port.disconnect();
        sub.cancel();
      });
    });

    test('clean rates behave like the MOCK port', () {
      FakeAsync().run((async) {
        final port = _port();
        addTearDown(port.disconnect);
        final chunks = <Uint8List>[];
        final sub = port.byteStream.listen(chunks.add);
        expect(port.connect(), isTrue);
        expect(port.isConnected, isTrue);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(chunks, isNotEmpty);

        // No random drop: still up after 30 virtual seconds.
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(port.isConnected, isTrue);

        // Reconnect starts over.
        port.disconnect();
        expect(port.isConnected, isFalse);
        expect(port.connect(), isTrue);
        expect(port.isConnected, isTrue);
        port.disconnect();
        sub.cancel();
      });
    });

    test('drop kills the link dead on the first tick', () {
      FakeAsync().run((async) {
        final port = _port(dropPerTick: 1.0);
        final chunks = <Uint8List>[];
        final sub = port.byteStream.listen(chunks.add);
        expect(port.connect(), isTrue);
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
        expect(port.isConnected, isFalse);
        // Nothing recovers on its own: still silent, still down.
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(chunks, isEmpty);
        expect(port.isConnected, isFalse);
        port.disconnect();
        sub.cancel();
      });
    });

    test('send flakiness only affects connected transmits', () {
      final alwaysNak = _port(sendFailureRate: 1.0);
      addTearDown(alwaysNak.disconnect);
      expect(alwaysNak.connect(), isTrue);
      expect(
        alwaysNak.sendBytes(Uint8List.fromList([0x54, 0x43, 0x01, 0x00])),
        isFalse,
      );
      // Still up (half-open TX stall, not a disconnect).
      expect(alwaysNak.isConnected, isTrue);

      final alwaysAck = _port();
      addTearDown(alwaysAck.disconnect);
      expect(alwaysAck.connect(), isTrue);
      expect(
        alwaysAck.sendBytes(Uint8List.fromList([0x54, 0x43, 0x01, 0x00])),
        isTrue,
      );

      alwaysNak.disconnect();
      expect(
        alwaysNak.sendBytes(Uint8List.fromList([0x54, 0x43, 0x01, 0x00])),
        isFalse,
      );
    });

    // NOTE: SerialService owns its MOCK-DC instance with default (random)
    // rates, so these assertions hold regardless of the chaos roll.
    test('SerialService routes MOCK-DC consistently', () {
      final service = SerialService();
      addTearDown(service.disconnect);
      final ok = service.connect(MockDcSerialPort.portName);
      expect(service.isConnected, ok);
      if (ok) {
        // Either outcome is a consistent answer (ack or flaky NAK).
        service.sendBytes(Uint8List.fromList([0x54, 0x43, 0x05, 0x00]));
      } else {
        expect(
          service.sendBytes(Uint8List.fromList([0x54, 0x43, 0x05, 0x00])),
          isFalse,
        );
      }
      service.disconnect();
      expect(service.isConnected, isFalse);
    });
  });
}
