import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/state/toast_store.dart';
import 'package:trycatch/ui/components/toast_overlay.dart';

class _SeededToasts extends ToastStore {
  final List<ToastMessage> seed;
  _SeededToasts(this.seed);

  @override
  List<ToastMessage> build() => seed;
}

Future<void> _pumpOverlay(
  WidgetTester tester,
  List<ToastMessage> toasts,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        toastStoreProvider.overrideWith(() => _SeededToasts(toasts)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Stack(children: [ToastOverlay()]),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Live overlay around a real [ToastStore] the test drives directly.
Future<ProviderContainer> _pumpLiveOverlay(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Stack(children: [ToastOverlay()]),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

ToastMessage _toast(int id, [String? message]) => ToastMessage(
      id: id,
      message: message ?? 'message $id',
      severity: ToastSeverity.error,
      title: 'Serial error',
      timestampMs: id,
    );

void main() {
  group('ToastOverlay', () {
    testWidgets('renders nothing when empty', (tester) async {
      await _pumpOverlay(tester, const []);
      expect(find.byType(ToastCard), findsNothing);
    });

    testWidgets('renders title + message + dismiss', (tester) async {
      await _pumpOverlay(tester, [_toast(0, 'Failed to open COM3')]);
      expect(find.text('Serial error'), findsOneWidget);
      expect(find.text('Failed to open COM3'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('caps visible cards to maxVisible, newest last',
        (tester) async {
      await _pumpOverlay(
        tester,
        [for (var i = 0; i < ToastStore.maxVisible + 2; i++) _toast(i)],
      );
      expect(find.byType(ToastCard), findsNWidgets(ToastStore.maxVisible));
      // Sonner bottom-right order: newest toast lands at the bottom edge.
      final cards = tester.widgetList<ToastCard>(find.byType(ToastCard));
      expect(cards.first.toast.id, 2);
      expect(cards.last.toast.id, ToastStore.maxVisible + 1);
    });

    testWidgets('severity colors the leading edge', (tester) async {
      await _pumpOverlay(
        tester,
        const [
          ToastMessage(
            id: 0,
            message: 'warn',
            severity: ToastSeverity.warning,
            timestampMs: 0,
          ),
        ],
      );
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    });

    testWidgets('pushed toast slides in and settles', (tester) async {
      final container = await _pumpLiveOverlay(tester);
      expect(find.byType(ToastCard), findsNothing);

      container
          .read(toastStoreProvider.notifier)
          .push('Failed to open COM4', title: 'Serial error');
      await tester.pump();
      // In the tree immediately (mid-enter-animation), settled a beat later.
      expect(find.text('Failed to open COM4'), findsOneWidget);
      await tester.pump(ToastOverlay.enterDuration);
      expect(find.text('Failed to open COM4'), findsOneWidget);
    });

    testWidgets('dismissed toast animates out and leaves', (tester) async {
      final container = await _pumpLiveOverlay(tester);
      container
          .read(toastStoreProvider.notifier)
          .push('boom', title: 'Serial error');
      await tester.pump();
      expect(find.byType(ToastCard), findsOneWidget);
      // Let the enter animation land so the close target is hittable.
      await tester.pump(ToastOverlay.enterDuration);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      // Still leaving mid-exit (no instant pop)...
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ToastCard), findsOneWidget);
      // ...gone once the exit has fully played out.
      await tester.pump(ToastOverlay.exitDuration * 2);
      await tester.pump();
      expect(find.byType(ToastCard), findsNothing);
      expect(container.read(toastStoreProvider), isEmpty);
    });

    testWidgets('programmatic dismiss removes the card', (tester) async {
      final container = await _pumpLiveOverlay(tester);
      final store = container.read(toastStoreProvider.notifier);
      store.push('boom', title: 'Serial error');
      await tester.pump();
      await tester.pump(ToastOverlay.enterDuration);
      expect(find.byType(ToastCard), findsOneWidget);

      store.dismiss(container.read(toastStoreProvider).single.id);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ToastCard), findsOneWidget);
      await tester.pump(ToastOverlay.exitDuration * 2);
      await tester.pump();
      expect(find.byType(ToastCard), findsNothing);
      expect(container.read(toastStoreProvider), isEmpty);
    });

    testWidgets('newest toast lands below older ones', (tester) async {
      final container = await _pumpLiveOverlay(tester);
      final store = container.read(toastStoreProvider.notifier);
      store.push('first');
      await tester.pump();
      store.push('second');
      await tester.pump();
      await tester.pump(ToastOverlay.enterDuration);

      final cards = tester.widgetList<ToastCard>(find.byType(ToastCard));
      expect([for (final c in cards) c.toast.message], ['first', 'second']);
    });

    testWidgets('action button runs callback and dismisses', (tester) async {
      final container = await _pumpLiveOverlay(tester);
      var ran = false;
      container.read(toastStoreProvider.notifier).push(
            'Section removed',
            severity: ToastSeverity.info,
            actionLabel: 'Undo',
            onAction: () => ran = true,
          );
      await tester.pump();
      await tester.pump(ToastOverlay.enterDuration);

      await tester.tap(find.text('UNDO'));
      await tester.pump();
      await tester.pump(ToastOverlay.exitDuration * 2);
      await tester.pump();
      expect(ran, isTrue);
      expect(container.read(toastStoreProvider), isEmpty);
    });
  });
}
