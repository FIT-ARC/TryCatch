import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/state/bridge_provider.dart';
import 'package:trycatch/ui/components/live_output_card.dart';

Future<ProviderContainer> _pumpCard(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: LiveOutputCard()),
      ),
    ),
  );
  await container.read(bridgeConfigProvider.future);
  await tester.pump();
  return container;
}

void main() {
  group('LiveOutputCard', () {
    testWidgets('toggle enables the bridge', (tester) async {
      final container = await _pumpCard(tester);
      expect(find.text('LIVE SHARING'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect((await container.read(bridgeConfigProvider.future)).enabled,
          true);
    });

    testWidgets('configure dialog saves port and bind', (tester) async {
      final container = await _pumpCard(tester);
      await tester.tap(find.text('Configure'));
      await tester.pump();
      expect(find.text('Live sharing settings'), findsOneWidget);

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), '6777');
      await tester.enterText(fields.at(1), '127.0.0.1');
      await tester.tap(find.text('Save'));
      await tester.pump();
      final config = await container.read(bridgeConfigProvider.future);
      expect(config.port, 6777);
      expect(find.text('Live sharing settings'), findsNothing);
    });

    testWidgets('configure dialog rejects a bad port inline', (tester) async {
      await _pumpCard(tester);
      await tester.tap(find.text('Configure'));
      await tester.pump();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '0');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Port must be a number from 1 to 65535.'),
          findsOneWidget);
      expect(find.text('Live sharing settings'), findsOneWidget);
    });
  });
}
