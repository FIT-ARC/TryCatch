import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/services/prefs_keys.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/toast_store.dart';
import 'package:trycatch/ui/screens/settings_screen.dart';

Map<String, dynamic> _site(String name) => {
      'name': name,
      'latitude': 50.0,
      'longitude': 14.0,
      'altitudeMsl': 300.0,
    };

/// Fail-fast HTTP: tile precaching resolves without touching the network.
class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FailingHttpClient();
}

class _FailingHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      Future.error(const SocketException('offline test'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Future<LaunchSiteState> _loadWithPrefs(Map<String, dynamic> stored) async {
  SharedPreferences.setMockInitialValues({
    PrefsKeys.launchSites: jsonEncode(stored),
  });
  final container = ProviderContainer();
  try {
    return await container.read(launchSiteProvider.future);
  } finally {
    container.dispose();
  }
}

void main() {
  group('LaunchSiteStore dev mock pad', () {
    test('fresh launch shows the mock pad selected (in memory only)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      try {
        final state = await container.read(launchSiteProvider.future);
        expect(state.presets.map((p) => p.name).toList(), ['MOCK Pad']);
        expect(state.selected?.name, 'MOCK Pad');
      } finally {
        container.dispose();
      }
    });

    test('stored presets gain the mock pad in memory', () async {
      final state = await _loadWithPrefs({
        'selected': _site('Idk'),
        'presets': [_site('Home')],
      });
      expect(state.selected?.name, 'Idk');
      expect(
        state.presets.map((p) => p.name).toList(),
        ['Home', 'MOCK Pad'],
      );
    });

    test('mock pad is never written to disk', () async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      final container = ProviderContainer();
      try {
        await container.read(launchSiteProvider.future);
        await container
            .read(launchSiteProvider.notifier)
            .savePreset(LaunchSite(
              name: 'Field',
              latitude: 51.0,
              longitude: 15.0,
              altitudeMsl: 300,
            ));
        final prefs = await SharedPreferences.getInstance();
        final disk = jsonDecode(prefs.getString(PrefsKeys.launchSites)!)
            as Map<String, dynamic>;
        expect(
          (disk['presets'] as List)
              .map((e) => (e as Map<String, dynamic>)['name']),
          ['Field', 'Home'],
        );
        final state = container.read(launchSiteProvider).value!;
        expect(
          state.presets.map((p) => p.name).toList(),
          ['Field', 'Home', 'MOCK Pad'],
        );
      } finally {
        container.dispose();
      }
    });

    test('mock pad cannot be deleted or overwritten', () async {
      final container = ProviderContainer();
      try {
        SharedPreferences.setMockInitialValues({
          PrefsKeys.launchSites: jsonEncode({
            'selected': _site('Home'),
            'presets': [_site('Home')],
          }),
        });
        await container.read(launchSiteProvider.future);
        await container
            .read(launchSiteProvider.notifier)
            .deletePreset('MOCK Pad');
        var state = container.read(launchSiteProvider).value!;
        expect(state.presets.map((p) => p.name), contains('MOCK Pad'));
        await container.read(launchSiteProvider.notifier).savePreset(
              const LaunchSite(
                name: 'MOCK Pad',
                latitude: 0,
                longitude: 0,
                altitudeMsl: 0,
              ),
            );
        state = container.read(launchSiteProvider).value!;
        final mock = state.presets.singleWhere((p) => p.name == 'MOCK Pad');
        expect(mock.latitude, 50.0755);
        expect(mock.longitude, 14.4378);
        expect(mock.altitudeMsl, 403);
        expect(state.selected?.name, 'MOCK Pad');
      } finally {
        container.dispose();
      }
    });

    test('share string round-trips the site', () {
      const site = LaunchSite(
        name: 'Home (Prague) pad',
        latitude: 50.0755,
        longitude: 14.4378,
        altitudeMsl: 403,
      );
      final shared = site.toShareString();
      expect(shared.startsWith(launchSiteSharePrefix), isTrue);
      final back = LaunchSite.parseShareString(shared);
      expect(back?.name, site.name);
      expect(back?.latitude, site.latitude);
      expect(back?.longitude, site.longitude);
      expect(back?.altitudeMsl, site.altitudeMsl);
      expect(LaunchSite.parseShareString('nope'), isNull);
      expect(LaunchSite.parseShareString('LAUNCHSITE1.!!!'), isNull);
    });
  });

  group('LaunchSiteStore saved-only invariant', () {
    test('loads stored selection as-is (mock injected alongside)', () async {
      final state = await _loadWithPrefs({
        'selected': _site('Idk'),
        'presets': [_site('Home')],
      });
      expect(state.selected?.name, 'Idk');
      expect(
        state.presets.map((p) => p.name).toList(),
        ['Home', 'MOCK Pad'],
      );
    });

    test('null selection loads as-is (invariant enforced on write)', () async {
      final state = await _loadWithPrefs({
        'selected': null,
        'presets': [_site('Alpha'), _site('Beta')],
      });
      expect(state.selected, isNull);
      expect(
        state.presets.map((p) => p.name).toList(),
        ['Alpha', 'Beta', 'MOCK Pad'],
      );
    });

    test('duplicates load as-is (savePreset dedupes on write)', () async {
      final state = await _loadWithPrefs({
        'selected': _site('Home'),
        'presets': [_site('Home'), _site('Home')],
      });
      expect(state.presets.where((p) => p.name == 'Home').length, 2);
      expect(state.selected?.name, 'Home');
    });

    test('empty disk still shows the dev mock pad', () async {
      final state = await _loadWithPrefs({
        'selected': null,
        'presets': [],
      });
      expect(state.selected, isNull);
      expect(state.presets.map((p) => p.name).toList(), ['MOCK Pad']);
    });

    test('deleting the last real preset falls back to the mock pad', () async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Solo'),
          'presets': [_site('Solo')],
        }),
      });
      final container = ProviderContainer();
      try {
        await container.read(launchSiteProvider.future);
        await container
            .read(launchSiteProvider.notifier)
            .deletePreset('Solo');
        final state = container.read(launchSiteProvider).value!;
        expect(state.presets.map((p) => p.name).toList(), ['MOCK Pad']);
        expect(state.selected?.name, 'MOCK Pad');
      } finally {
        container.dispose();
      }
    });

    test('deleting the active preset falls through to another', () async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Beta'),
          'presets': [_site('Alpha'), _site('Beta')],
        }),
      });
      final container = ProviderContainer();
      try {
        await container.read(launchSiteProvider.future);
        await container
            .read(launchSiteProvider.notifier)
            .deletePreset('Beta');
        final state = container.read(launchSiteProvider).value!;
        expect(
          state.presets.map((p) => p.name).toList(),
          ['Alpha', 'MOCK Pad'],
        );
        expect(state.selected?.name, 'Alpha');
      } finally {
        container.dispose();
      }
    });
  });

  group('SettingsScreen', () {
    // Launch-site editing moved to the top-bar dialog; settings keeps
    // offline maps + appearance. A stray selection must still load cleanly.
    testWidgets('stray selection loads without throwing', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Idk'),
          'presets': [],
        }),
      });
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('OFFLINE MAPS'), findsOneWidget);
    });

    testWidgets('connector picker locks while connected', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serialStatusProvider.overrideWith(
              (ref) => Stream.value(const SerialWorkerStatus(
                isConnected: true,
                connectedPort: 'MOCK',
              )),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.text('Locked while connected — disconnect to switch.'),
        findsOneWidget,
      );
      final absorbers = tester.widgetList<AbsorbPointer>(
        find.byWidgetPredicate(
            (w) => w is AbsorbPointer && w.absorbing),
      );
      expect(absorbers, isNotEmpty);
    });

    testWidgets('connector picker locks while recording', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serialStatusProvider.overrideWith(
              (ref) => Stream.value(const SerialWorkerStatus(
                isConnected: true,
                connectedPort: 'MOCK',
                isRecording: true,
              )),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.text(
            'Locked while recording — the file stamps this connector.'),
        findsOneWidget,
      );
    });
    testWidgets('launch site card selects inline with add action',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('LAUNCH SITE'), findsOneWidget);
      // The site name also appears in the offline-maps rows below.
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Add'), findsOneWidget);
      // Per-row management: share copies, edit and delete manage.
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('launch site change locks while recording', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            serialStatusProvider.overrideWith(
              (ref) => Stream.value(const SerialWorkerStatus(
                isRecording: true,
              )),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.text('Locked while recording — the file stamps this site.'),
        findsOneWidget,
      );
      final addButton =
          find.widgetWithText(OutlinedButton, 'Add');
      expect(addButton, findsOneWidget);
      expect(tester.widget<OutlinedButton>(addButton).onPressed, isNull);
    });

    testWidgets('row delete offers undo that restores the preset',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await container.read(launchSiteProvider.future);
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      var state = container.read(launchSiteProvider).value!;
      expect(state.presets.map((p) => p.name), isNot(contains('Home')));
      final toast = container.read(toastStoreProvider).last;
      expect(toast.actionLabel, 'Undo');

      toast.onAction!();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        state = container.read(launchSiteProvider).value!;
        if (state.presets.any((p) => p.name == 'Home')) break;
      }
      expect(state.presets.map((p) => p.name), contains('Home'));
      expect(state.selected?.name, 'Home');
    });

    testWidgets('selecting a connector moves no row heights',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      List<double> rowHeights() => [
            for (final c in tester.widgetList<Container>(
              find.byWidgetPredicate((w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).border is Border),
            ))
              tester.getSize(find.byWidget(c)).height,
          ];

      final before = rowHeights();
      expect(before, isNotEmpty);
      // MOCK is selected by default in debug; pick another option.
      await tester.tap(find.text('Rocket v1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(rowHeights(), before);
    });

    testWidgets('add dialog has one close path and validates', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Add'));
      await tester.pump();
      expect(find.text('Add site'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Close'), findsNothing);

      // Empty name validates in place, dialog stays open.
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Give the site a name.'), findsOneWidget);
      expect(find.text('Add site'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Add site'), findsNothing);
    });

    testWidgets('import dialog saves a pasted share string',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await container.read(launchSiteProvider.future);
      await tester.pump();

      await tester.tap(find.text('Import'));
      await tester.pump();
      expect(find.text('Import site'), findsOneWidget);
      const shared = LaunchSite(
        name: 'Shared Pad',
        latitude: 51.0,
        longitude: 15.0,
        altitudeMsl: 300,
      );
      await tester.enterText(
          find.byType(TextField), shared.toShareString());
      await tester.tap(find.text('Import').last);
      await tester.pump();
      final state = container.read(launchSiteProvider).value!;
      expect(state.presets.map((p) => p.name),
          containsAll(['Home', 'Shared Pad']));
      expect(state.selected?.name, 'Shared Pad');
      expect(find.text('Import site'), findsNothing);
    });

    testWidgets('add dialog saves a typed site', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Home'),
          'presets': [_site('Home')],
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      HttpOverrides.global = _OfflineHttpOverrides();
      addTearDown(() => HttpOverrides.global = null);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await container.read(launchSiteProvider.future);
      await tester.pump();

      await tester.tap(find.text('Add'));
      await tester.pump();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Field');
      await tester.enterText(fields.at(1), '51');
      await tester.enterText(fields.at(2), '15');
      await tester.enterText(fields.at(3), '300');
      await tester.tap(find.text('Save'));
      await tester.pump();
      final state = container.read(launchSiteProvider).value!;
      expect(
          state.presets.map((p) => p.name), containsAll(['Home', 'Field']));
      expect(state.selected?.name, 'Field');
      expect(find.text('Add site'), findsNothing);
    });
  });
}
