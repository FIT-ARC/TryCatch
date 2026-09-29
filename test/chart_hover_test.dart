import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/state/chart_hover_store.dart';

/// Shared replay hover: one seconds-since-launch x syncs every whole-flight
/// chart, and the nearest-sample lookup resolves it per chart.
void main() {
  group('chartHoverProvider', () {
    test('starts with no hover', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(chartHoverProvider), isNull);
    });

    test('hover publishes x, clear drops it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chartHoverProvider.notifier);
      notifier.hover(12.5);
      expect(container.read(chartHoverProvider), 12.5);
      notifier.hover(13.0);
      expect(container.read(chartHoverProvider), 13.0);
      notifier.clear();
      expect(container.read(chartHoverProvider), isNull);
    });

    test('clear is idempotent', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chartHoverProvider.notifier);
      notifier.clear();
      expect(container.read(chartHoverProvider), isNull);
      notifier.hover(1.0);
      notifier.clear();
      notifier.clear();
      expect(container.read(chartHoverProvider), isNull);
    });
  });

  group('nearestIndexForX', () {
    test('empty returns -1', () {
      expect(nearestIndexForX(const [], 5), -1);
    });

    test('exact hits and edges', () {
      const xs = [0.0, 10.0, 20.0];
      expect(nearestIndexForX(xs, 0), 0);
      expect(nearestIndexForX(xs, 20), 2);
      expect(nearestIndexForX(xs, -100), 0);
      expect(nearestIndexForX(xs, 100), 2);
    });

    test('between samples picks the nearer, ties go earlier', () {
      const xs = [0.0, 10.0, 20.0];
      expect(nearestIndexForX(xs, 7), 1);
      expect(nearestIndexForX(xs, 3), 0);
      expect(nearestIndexForX(xs, 5), 0);
      expect(nearestIndexForX(xs, 15), 1);
    });

    test('single sample always wins', () {
      expect(nearestIndexForX(const [4.0], 999), 0);
    });
  });
}
