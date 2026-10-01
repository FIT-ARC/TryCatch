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
      // No server state worth showing while off or not yet running —
      // the toggle already says it.
      expect(find.textContaining('Running'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect((await container.read(bridgeConfigProvider.future)).enabled,
          true);
      expect(find.textContaining('Running'), findsNothing);
    });

    testWidgets('toggle stays disabled over invalid input', (tester) async {
      final container = await _pumpCard(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '0');
      await tester.pump();
      expect(find.text('Port must be a number from 1 to 65535.'),
          findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(
        (await container.read(bridgeConfigProvider.future)).enabled,
        false,
      );

      // Fixing the input re-enables the toggle.
      await tester.enterText(fields.at(1), '6777');
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNotNull,
      );
    });

    testWidgets('fields lock while the server is enabled', (tester) async {
      await _pumpCard(tester);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      // Locked via readOnly, so the look never changes with state.
      for (var i = 0; i < 3; i++) {
        final field = tester.widget<TextField>(fields.at(i));
        expect(field.readOnly, true);
        expect(field.canRequestFocus, false);
      }

      // Switching off unlocks them again.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        final field = tester.widget<TextField>(fields.at(i));
        expect(field.readOnly, false);
        expect(field.canRequestFocus, true);
      }
    });

    testWidgets('running box shows client count', (tester) async {
      final container = await _pumpCard(tester);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      container.read(bridgeStatusProvider.notifier).report(
            running: true,
            port: 6767,
            bind: '127.0.0.1',
            clients: 2,
            hasFrame: true,
          );
      await tester.pump();
      expect(find.text('Running · 2 clients connected'), findsOneWidget);
    });

    testWidgets('inline fields save port and bind', (tester) async {
      final container = await _pumpCard(tester);
      // Order: bind address, port, allowed origin.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(1), '6777');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.enterText(fields.at(0), '127.0.0.1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final config = await container.read(bridgeConfigProvider.future);
      expect(config.port, 6777);
    });

    testWidgets('inline fields reject a bad port', (tester) async {
      await _pumpCard(tester);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Port must be a number from 1 to 65535.'),
          findsOneWidget);
    });
  });
}
