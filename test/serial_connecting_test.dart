import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/toast_store.dart';
import 'package:trycatch/ui/components/serial_controls.dart';
import 'package:trycatch/ui/components/serial_toast_bridge.dart';

/// The pill's connecting state ([SerialConfig.connectingPort]) plus the
/// rescan toast, exercised against the real worker isolate.
///
/// NOTE: these tests pump real widgets ([SerialToastBridge]/[SerialControls])
/// around a bare [ProviderContainer]. That is load-bearing, not ceremony:
/// `ref.listen` outside a widget `build` does not reliably deliver stream
/// events, so the connect-clear and rescan-toast subscriptions live in the
/// widgets — a container-only test would wait forever (probed 2026-09).
void main() {
  late SerialWorker worker;
  Timer? ping;

  setUpAll(() async {
    worker = await SerialWorker.spawn();
    await worker.ready;
    // Liveness lease: ping like the app does, so the worker cannot
    // self-exit mid-file on a slow runner. setUpAll runs outside the
    // widget fake-async zone, so this is a real timer.
    ping = Timer.periodic(
      const Duration(seconds: 2),
      (_) => worker.send(const PingCommand()),
    );
  });

  tearDownAll(() {
    ping?.cancel();
    worker.dispose();
  });

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [
        serialWorkerProvider.overrideWithValue(worker),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> pumpHarness(
    WidgetTester tester,
    Widget child,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: Center(child: child))),
      ),
    );
    await tester.pump();
    return container;
  }

  Future<void> waitFor(
    bool Function() done, {
    String reason = 'condition not met in time',
  }) async {
    // NOTE: callers inside `testWidgets` must invoke this within
    // `tester.runAsync` — the widget fake-async zone freezes both
    // `DateTime` and `Future.delayed`, which would loop forever.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TestFailure(reason);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  group('connecting state', () {
    testWidgets('failed connect spins, then errors and clears', (
      tester,
    ) async {
      final container = newContainer();
      await pumpHarness(tester, const SerialToastBridge(), container);
      // The pill owns the success path; mount it too so the status
      // subscription is live (and prove it stays out of the way here).
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Column(
                children: [SerialToastBridge(), SerialControls()],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final notifier = container.read(serialConfigProvider.notifier);
      notifier.setPort('__BOGUS_PORT_XYZ__');
      notifier.connect();
      expect(container.read(serialConfigProvider).connectingPort,
          '__BOGUS_PORT_XYZ__');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.runAsync(() async {
        await waitFor(
          () => container.read(serialConfigProvider).connectingPort == null,
          reason: 'connectingPort never cleared after failed connect',
        );
      });
      await tester.pump();
      final toasts = container.read(toastStoreProvider);
      expect(
        toasts.any((t) =>
            t.title == 'Serial error' &&
            t.message.contains('__BOGUS_PORT_XYZ__')),
        isTrue,
      );
      expect(
        container.read(serialStatusProvider).value?.isConnected ?? false,
        isFalse,
      );
    });

    testWidgets('MOCK connect spins, then links up and clears', (
      tester,
    ) async {
      final container = newContainer();
      await pumpHarness(tester, const SerialControls(), container);

      container.read(serialConfigProvider.notifier).setPort('MOCK');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.link));
      await tester.pump();
      expect(container.read(serialConfigProvider).connectingPort, 'MOCK');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.runAsync(() async {
        await waitFor(
          () =>
              container.read(serialStatusProvider).value?.isConnected ?? false,
          reason: 'MOCK never reported connected',
        );
      });
      expect(container.read(serialConfigProvider).connectingPort, isNull);
      await tester.pump();
      expect(find.byIcon(Icons.link_off), findsOneWidget);

      container.read(serialConfigProvider.notifier).disconnect();
      await tester.runAsync(() async {
        await waitFor(
          () =>
              !(container.read(serialStatusProvider).value?.isConnected ??
                  true),
          reason: 'MOCK never reported disconnected',
        );
      });
    });

    testWidgets('rescan pushes one Ports refreshed toast', (tester) async {
      final container = newContainer();
      await pumpHarness(tester, const SerialToastBridge(), container);

      container.read(serialConfigProvider.notifier).refreshPorts();
      await tester.runAsync(() async {
        await waitFor(
          () => container
              .read(toastStoreProvider)
              .any((t) => t.title == 'Ports refreshed'),
          reason: 'no Ports refreshed toast arrived after rescan',
        );
      });
      // Exactly one — the startup scan must stay silent.
      expect(
        container
            .read(toastStoreProvider)
            .where((t) => t.title == 'Ports refreshed'),
        hasLength(1),
      );
    });

    testWidgets('mid-connect tap explains instead of dying', (tester) async {
      final container = ProviderContainer(
        overrides: [
          serialStatusProvider.overrideWith(
            (ref) => Stream.value(const SerialWorkerStatus()),
          ),
          availablePortsProvider.overrideWith(
            (ref) => Stream.value(const ['COM4']),
          ),
          serialConfigProvider.overrideWith(_ConnectingConfig.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: Center(child: SerialControls())),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('COM4…'), findsOneWidget);

      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();
      final toasts = container.read(toastStoreProvider);
      expect(toasts, hasLength(1));
      expect(toasts.single.title, 'Connecting');
      expect(tester.takeException(), isNull);
    });
  });

  group('SerialToastBridge.isDisconnectMessage', () {
    test('classifies link-loss text as disconnects', () {
      expect(
          SerialToastBridge.isDisconnectMessage('Port disconnected — COM4'),
          isTrue);
      expect(SerialToastBridge.isDisconnectMessage('Port closed — COM4'),
          isTrue);
      expect(SerialToastBridge.isDisconnectMessage('Port error: boom'),
          isTrue);
      expect(SerialToastBridge.isDisconnectMessage('Failed to open COM4'),
          isFalse);
      expect(
          SerialToastBridge.isDisconnectMessage(
              'Not connected — failed to send 4 byte(s)'),
          isFalse);
    });
  });
}

/// Seeds [SerialConfig] with an in-flight COM4 attempt.
class _ConnectingConfig extends SerialConfigNotifier {
  _ConnectingConfig();

  @override
  SerialConfig build() =>
      const SerialConfig(selectedPort: 'COM4', connectingPort: 'COM4');
}
