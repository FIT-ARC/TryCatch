import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/toast_store.dart';
import 'package:trycatch/ui/components/serial_toast_bridge.dart';

/// Pumps the headless bridge with overridable serial streams and returns
/// the container for toast assertions.
Future<ProviderContainer> _pumpBridge(
  WidgetTester tester, {
  Stream<ErrorEvent>? errors,
  Stream<SerialWorkerStatus>? statuses,
  Stream<CommandResultEvent>? commands,
}) async {
  final container = ProviderContainer(
    overrides: [
      serialErrorsProvider.overrideWith(
        (ref) => errors ?? const Stream<ErrorEvent>.empty(),
      ),
      serialStatusProvider.overrideWith(
        (ref) => statuses ?? const Stream<SerialWorkerStatus>.empty(),
      ),
      commandEventsProvider.overrideWith(
        (ref) => commands ?? const Stream<CommandResultEvent>.empty(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SerialToastBridge()),
      ),
    ),
  );
  return container;
}

void main() {
  group('SerialToastBridge', () {
    testWidgets('worker errors become error toasts', (tester) async {
      final container = await _pumpBridge(
        tester,
        errors: Stream.value(ErrorEvent('Failed to open COM3')),
      );
      await tester.pump();
      await tester.pump();
      final toasts = container.read(toastStoreProvider);
      expect(toasts, hasLength(1));
      expect(toasts.single.message, 'Failed to open COM3');
      expect(toasts.single.severity, ToastSeverity.error);
      expect(toasts.single.title, 'Serial error');
    });

    testWidgets('disconnect errors become warning toasts', (tester) async {
      final container = await _pumpBridge(
        tester,
        errors: Stream.value(ErrorEvent('Port disconnected — COM3')),
      );
      await tester.pump();
      await tester.pump();
      final toasts = container.read(toastStoreProvider);
      expect(toasts, hasLength(1));
      expect(toasts.single.message, 'Port disconnected — COM3');
      expect(toasts.single.severity, ToastSeverity.warning);
      expect(toasts.single.title, 'Port disconnected');
    });

    testWidgets('status flips alone stay silent (e.g. manual disconnect)',
        (tester) async {
      final container = await _pumpBridge(
        tester,
        statuses: Stream<SerialWorkerStatus>.fromIterable(const [
          SerialWorkerStatus(isConnected: true, connectedPort: 'COM3'),
          SerialWorkerStatus(isConnected: false),
        ]),
      );
      await tester.pump();
      await tester.pump();
      expect(container.read(toastStoreProvider), isEmpty);
    });

    testWidgets('failed uplink attempts become error toasts', (tester) async {
      final container = await _pumpBridge(
        tester,
        commands: Stream.value(
          CommandResultEvent(
            bytes: Uint8List.fromList([0x54, 0x43, 0x01, 0x00]),
            timestampMs: 1,
            ok: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final toasts = container.read(toastStoreProvider);
      expect(toasts, hasLength(1));
      expect(toasts.single.title, 'Command failed');
      expect(toasts.single.message, contains('Arm'));
    });

    testWidgets('successful uplinks stay silent', (tester) async {
      final container = await _pumpBridge(
        tester,
        commands: Stream.value(
          CommandResultEvent(
            bytes: Uint8List.fromList([0x54, 0x43, 0x01, 0x00]),
            timestampMs: 1,
            ok: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(container.read(toastStoreProvider), isEmpty);
    });
  });

  group('ErrorEvent', () {
    test('carries a timestamp by default', () {
      final event = ErrorEvent('boom');
      expect(event.message, 'boom');
      expect(event.timestampMs, greaterThan(0));
    });
  });
}
