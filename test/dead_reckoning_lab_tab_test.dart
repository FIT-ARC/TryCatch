import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart'
    show FrameFlags, FsmState, TelemetryFrame;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/dead_reckoning_tune_store.dart';
import 'package:trycatch/ui/components/toast_overlay.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/screens/dead_reckoning_lab_tab.dart';

class _StubStore extends TelemetryStore {
  @override
  TelemetryState build() => TelemetryState(
        history: RingBuffer<TelemetryFrame>(10),
        deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
      );
}

/// 31 s climbing leg with a fix every second (stays airborne through
/// masked gaps so outages score instead of grounding).
List<DeadReckoningSample> _climbingLeg() => [
      for (var t = 0; t <= 30; t++)
        DeadReckoningSample(
          receivedAtMs: t * 1000,
          latitude: 50 + (10 * t) / 111320,
          longitude: 14,
          gpsAltitude: 500 + 30.0 * t,
          velocityNorth: 10,
          velocityDown: -30,
        ),
    ];

List<TelemetryFrame> _climbingFrames() => [
      for (var t = 0; t <= 30; t++)
        TelemetryFrame(
          receivedAtMs: t * 1000,
          flags: FrameFlags.gpsFix,
          sequence: t,
          latitude: 50 + (10 * t) / 111320,
          longitude: 14,
          gpsAltitude: 500 + 30.0 * t,
          velocityNorth: 10,
          velocityDown: -30,
          fsmStateId: FsmState.ascent.id,
        ),
    ];

/// Short mixed-phase flight: ascent, then parachute, then landed. The
/// landed stretch must never show up in outage coverage.
List<DeadReckoningSample> _mixedLeg() => [
      for (var t = 0; t <= 30; t++)
        DeadReckoningSample(
          receivedAtMs: t * 1000,
          latitude: 50 + (10 * t) / 111320,
          longitude: 14,
          gpsAltitude: 500 + 30.0 * t,
          velocityNorth: 10,
          velocityDown: -30,
        ),
    ];

List<TelemetryFrame> _mixedFrames() => [
      for (var t = 0; t <= 30; t++)
        TelemetryFrame(
          receivedAtMs: t * 1000,
          flags: FrameFlags.gpsFix,
          sequence: t,
          latitude: 50 + (10 * t) / 111320,
          longitude: 14,
          gpsAltitude: 500 + 30.0 * t,
          velocityNorth: 10,
          velocityDown: -30,
          fsmStateId: t < 10
              ? FsmState.ascent.id
              : t < 25
                  ? FsmState.parachute.id
                  : FsmState.landed.id,
        ),
    ];

/// Leg whose sensor under-reads: positions advance at 10 m/s but report
/// 7 m/s, so the search must find a scale above 1 and the preview shows
/// the previous tune's guess next to the new one.
List<DeadReckoningSample> _underreadingLeg() => [
      for (var t = 0; t <= 60; t++)
        DeadReckoningSample(
          receivedAtMs: t * 1000,
          latitude: 50 + (10 * t) / 111320,
          longitude: 14,
          gpsAltitude: 500 + 3.0 * t,
          velocityNorth: 7,
          velocityDown: -3,
        ),
    ];

Widget _page({
  ProviderContainer? container,
  List<DeadReckoningSample>? samples,
  List<TelemetryFrame>? frames,
  String name = 'bench flight',
}) {
  final page = MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          DeadReckoningLabTab(
            debugSamples: samples ?? _climbingLeg(),
            debugFrames: frames ?? _climbingFrames(),
            debugName: name,
            loadTerrain: false,
          ),
          const ToastOverlay(),
        ],
      ),
    ),
  );
  if (container == null) {
    return ProviderScope(
      overrides: [telemetryStoreProvider.overrideWith(_StubStore.new)],
      child: page,
    );
  }
  return UncontrolledProviderScope(container: container, child: page);
}

/// Brings a page row on screen by dragging the page list itself: every
/// text field hosts its own inner scrollable, so the default lookup is
/// ambiguous, and lazily-built rows need explicit drags. Searches
/// downward first, then upward.
Future<void> _scrollToPage(WidgetTester tester, Finder finder) async {
  final scrollable = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
  );
  for (final dy in const [-300.0, 300.0]) {
    for (var i = 0; i < 20; i++) {
      final matches = finder.evaluate();
      if (matches.isNotEmpty) {
        final y = tester.getCenter(finder).dy;
        if (y >= 60 && y <= 540) return;
        await tester.drag(scrollable, Offset(0, y < 60 ? 300 : -300));
      } else {
        await tester.drag(scrollable, Offset(0, dy));
      }
      await tester.pumpAndSettle();
    }
  }
}

void main() {
  testWidgets('overview shows the current tune and the wizard door',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_page());
    await tester.pump();

    // Home state: headline, one tune line with a copy button, wizard
    // and manual doors — no paragraphs, no numbers, no rail.
    expect(find.text('Dead reckoning'), findsOneWidget);
    expect(find.text('Copy / Paste tune'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Generate new tune'), findsOneWidget);
    expect(find.text('Manual tune…'), findsOneWidget);
    expect(find.text('Factory settings'), findsNothing);
    expect(find.text('Velocity scale'), findsNothing);
    expect(find.text('Flight'), findsNothing);
    expect(find.text('Results'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guided flow runs, compares and applies', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [telemetryStoreProvider.overrideWith(_StubStore.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_page(container: container));
    await tester.pump();

    // Overview → Flight. The bench flight is picked and confirmed
    // straight into the search — no knobs, no coverage preamble.
    await tester.tap(find.text('Generate new tune'));
    await tester.pumpAndSettle();
    expect(find.text('bench flight'), findsWidgets);
    expect(find.text('Find best tune'), findsOneWidget);

    // Confirming runs the search and lands on Results. The steady leg
    // teaches nothing, so the identical tune reports Already optimal —
    // never a win on rounding noise.
    await tester.tap(find.text('Find best tune'));
    await tester.pumpAndSettle(const Duration(seconds: 30));
    expect(find.textContaining('Already optimal'), findsWidgets);
    // Legend explains the tracks; one outage means no paging.
    expect(find.text('Flown'), findsOneWidget);
    expect(find.text('New guess'), findsOneWidget);
    expect(find.text('Actual'), findsOneWidget);
    expect(find.text('Current'), findsNothing);
    expect(find.textContaining('Outage 1 of 1'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    // Applying returns home, where the tune text is shown live.
    await _scrollToPage(tester, find.text('Apply new tune'));
    await tester.tap(find.text('Apply new tune'));
    await tester.pumpAndSettle();
    expect(find.text('New tune applied.'), findsOneWidget);
    expect(find.text('Dead reckoning'), findsOneWidget);
    expect(find.textContaining('DEADRECKONING1.'), findsOneWidget);
    expect(container.read(deadReckoningTuneProvider),
        DeadReckoningTune.defaults);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landed phase is excluded from coverage', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_page(
      samples: _mixedLeg(),
      frames: _mixedFrames(),
      name: 'mixed flight',
    ));
    await tester.pump();

    // Ascent top-up plus the parachute window — nothing starting in
    // the landed stretch.
    await tester.tap(find.text('Generate new tune'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find best tune'));
    await tester.pumpAndSettle(const Duration(seconds: 30));
    expect(find.textContaining('Outage 1 of 2'), findsOneWidget);
    expect(find.textContaining('Landed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview uses pink for the actual continuation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [telemetryStoreProvider.overrideWith(_StubStore.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_page(
      container: container,
      samples: _underreadingLeg(),
      frames: const [],
      name: 'drifty flight',
    ));
    await tester.pump();

    await tester.tap(find.text('Generate new tune'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find best tune'));
    await tester.pumpAndSettle(const Duration(seconds: 90));

    // The search found a scale above 1: the rows compare means in
    // metres and the legend names three tracks, Actual in pink.
    expect(find.text('Average miss'), findsOneWidget);
    expect(find.text('Vertical error'), findsOneWidget);
    expect(find.text('Flown'), findsOneWidget);
    expect(find.text('New guess'), findsOneWidget);
    expect(find.text('Actual'), findsOneWidget);
    expect(find.text('Current'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);

    // Carousel pages through the outages.
    expect(find.textContaining('Outage 1 of 3'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.textContaining('Outage 2 of 3'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.textContaining('Outage 1 of 3'), findsOneWidget);

    // Applying lands home on the fitted tune.
    await _scrollToPage(tester, find.text('Apply new tune'));
    await tester.tap(find.text('Apply new tune'));
    await tester.pumpAndSettle();
    expect(find.text('New tune applied.'), findsOneWidget);
    expect(
      container.read(deadReckoningTuneProvider).velocityScale,
      greaterThan(1.2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('discarding results returns home', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_page());
    await tester.pump();

    await tester.tap(find.text('Generate new tune'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find best tune'));
    await tester.pumpAndSettle(const Duration(seconds: 30));
    expect(find.textContaining('Already optimal'), findsWidgets);
    await _scrollToPage(tester, find.text('Discard'));
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    // Discarding leaves the wizard: back home, no results anywhere.
    expect(find.text('Generate new tune'), findsOneWidget);
    expect(find.textContaining('Already optimal'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview pastes and loads tunes inline', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [telemetryStoreProvider.overrideWith(_StubStore.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_page(container: container));
    await tester.pump();

    // The line shows the live tune with a copy button, not Apply.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Apply'), findsNothing);

    // Pasting over it morphs copy into apply; garbage is rejected.
    await tester.enterText(find.byType(TextField), 'nope');
    await tester.pump();
    expect(find.text('Apply'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.textContaining('Not a tune'), findsOneWidget);

    // A real tune string loads, applies live, and morphs back to copy.
    const loaded = DeadReckoningTune(horizontalDrag: 0.03);
    await tester.enterText(
        find.byType(TextField), loaded.toCompactString());
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Tune loaded.'), findsOneWidget);
    expect(find.text('Apply'), findsNothing);
    expect(
      container.read(deadReckoningTuneProvider).horizontalDrag,
      closeTo(0.03, 1e-9),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual dialog rejects bad numbers', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_page());
    await tester.pump();

    await tester.tap(find.text('Manual tune…'));
    await tester.pumpAndSettle();
    expect(find.text('Velocity scale'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('tune-scale')));
    await tester.enterText(
        find.byKey(const ValueKey('tune-scale')), 'abc');
    await tester.ensureVisible(find.text('Use this tune'));
    await tester.tap(find.text('Use this tune'));
    await tester.pump();
    expect(find.textContaining('Velocity scale must be'), findsOneWidget);
    // Still open — Cancel backs out.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Velocity scale'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual dialog saves a custom scale', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [telemetryStoreProvider.overrideWith(_StubStore.new)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(_page(container: container));
    await tester.pump();

    await tester.tap(find.text('Manual tune…'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('tune-scale')));
    await tester.enterText(
        find.byKey(const ValueKey('tune-scale')), '1.2');
    await tester.ensureVisible(find.text('Use this tune'));
    await tester.tap(find.text('Use this tune'));
    await tester.pumpAndSettle();

    expect(
      container.read(deadReckoningTuneProvider).velocityScale,
      closeTo(1.2, 1e-9),
    );
    expect(find.text('Tune applied live and saved.'), findsOneWidget);
    expect(find.text('Use this tune'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
