import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/state/bridge_provider.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/components/top_bar.dart';

/// The live-sharing status light beside the quick nav: info only, hidden
/// while off, satellite + count while on, crossed satellite + `!` on error.
Future<ProviderContainer> _pumpBar(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      availablePortsProvider
          .overrideWith((ref) => Stream.value(const <String>[])),
      serialStatusProvider.overrideWith(
          (ref) => Stream.value(const SerialWorkerStatus())),
      telemetryStreamProvider.overrideWith(
          (ref) => Stream<TelemetryFrame>.empty()),
      linkStatsStreamProvider
          .overrideWith((ref) => Stream<LinkStats>.empty()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        // ignore: prefer_const_constructors — fresh instances on purpose.
        home: Scaffold(
          body: Column(
            children: [
              TopBar(),
              Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ),
  );
  await container.read(bridgeConfigProvider.future);
  await tester.pump();
  return container;
}

void main() {
  group('LiveShareStatus', () {
    testWidgets('off shows gray crossed satellite, on shows count, error alerts',
        (tester) async {
      final container = await _pumpBar(tester);
      var offIcon = tester.widget<Icon>(
        find.byIcon(Icons.satellite_alt_outlined),
      );
      expect(offIcon.color, AppColors.mutedForeground);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('!'), findsNothing);

      await container
          .read(bridgeConfigProvider.notifier)
          .setEnabled(true);
      await tester.pump();
      container.read(bridgeStatusProvider.notifier).report(
            running: true,
            port: 6767,
            bind: '127.0.0.1',
            clients: 2,
            hasFrame: true,
          );
      await tester.pump();
      final onIcon = tester.widget<Icon>(
        find.byIcon(Icons.satellite_alt_outlined).first,
      );
      expect(onIcon.color, AppColors.success);
      expect(find.text('2'), findsOneWidget);

      container.read(bridgeStatusProvider.notifier).report(
            running: false,
            port: 6767,
            bind: '127.0.0.1',
            clients: 0,
            hasFrame: false,
            error: 'Port 6767 is busy — retrying automatically',
          );
      await tester.pump();
      final errIcon = tester.widget<Icon>(
        find.byIcon(Icons.satellite_alt_outlined).first,
      );
      expect(errIcon.color, AppColors.destructive);
      expect(find.text('!'), findsOneWidget);
    });
  });
}
