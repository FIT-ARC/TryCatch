import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/state/toast_store.dart';

void main() {
  group('ToastStore', () {
    test('push adds a toast with id and timestamp', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final id = container
          .read(toastStoreProvider.notifier)
          .push('boom', severity: ToastSeverity.error, title: 'Serial error');
      final toasts = container.read(toastStoreProvider);
      expect(toasts, hasLength(1));
      expect(toasts.single.id, id);
      expect(toasts.single.message, 'boom');
      expect(toasts.single.title, 'Serial error');
      expect(toasts.single.severity, ToastSeverity.error);
    });

    test('identical messages stack as separate cards', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(toastStoreProvider.notifier);
      final first = notifier.push('same');
      final second = notifier.push('same');
      expect(first, isNot(second));
      expect(container.read(toastStoreProvider), hasLength(2));
      // A different message stacks normally.
      notifier.push('other');
      expect(container.read(toastStoreProvider), hasLength(3));
    });

    test('dismiss removes by id and ignores unknown ids', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(toastStoreProvider.notifier);
      final id = notifier.push('a');
      notifier.push('b');
      notifier.dismiss(9999);
      expect(container.read(toastStoreProvider), hasLength(2));
      notifier.dismiss(id);
      expect(container.read(toastStoreProvider), hasLength(1));
      expect(container.read(toastStoreProvider).single.message, 'b');
    });

    test('queue is bounded to maxEntries', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(toastStoreProvider.notifier);
      for (var i = 0; i < ToastStore.maxEntries + 5; i++) {
        notifier.push('msg $i');
      }
      final toasts = container.read(toastStoreProvider);
      expect(toasts.length, ToastStore.maxEntries);
      expect(toasts.last.message, 'msg ${ToastStore.maxEntries + 4}');
    });

    test('clear empties the queue', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(toastStoreProvider.notifier);
      notifier.push('a');
      notifier.push('b');
      notifier.clear();
      expect(container.read(toastStoreProvider), isEmpty);
    });
  });
}
