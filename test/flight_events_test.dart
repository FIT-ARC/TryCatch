import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/flight_events.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/ui/components/flight_event_style.dart';
import 'package:trycatch/ui/components/playback_bar.dart';

TelemetryFrame _frame(int atMs, FsmState state) =>
    TelemetryFrame(receivedAtMs: atMs, fsmStateId: state.id);

void main() {
  group('detectFlightEvents', () {
    test(
      'nominal flight yields launch/apogee/parachute/touchdown in order',
      () {
        final frames = [
          _frame(1000, FsmState.idle),
          _frame(2000, FsmState.armed),
          _frame(3000, FsmState.ascent),
          _frame(4000, FsmState.ascent),
          _frame(5000, FsmState.apogee),
          _frame(6000, FsmState.parachute),
          _frame(7000, FsmState.landed),
        ];
        final events = detectFlightEvents(frames);
        expect(events.map((e) => e.type), [
          FlightEventType.launch,
          FlightEventType.apogee,
          FlightEventType.parachute,
          FlightEventType.touchdown,
        ]);
        expect(events.map((e) => e.positionMs), [2000, 4000, 5000, 6000]);
        expect(events.map((e) => e.receivedAtMs), [3000, 5000, 6000, 7000]);
        expect(events.map((e) => e.frameIndex), [2, 4, 5, 6]);
      },
    );

    test('empty, single-frame and transition-free flights yield no events', () {
      expect(detectFlightEvents(const []), isEmpty);
      expect(detectFlightEvents([_frame(0, FsmState.armed)]), isEmpty);
      expect(
        detectFlightEvents([
          _frame(0, FsmState.idle),
          _frame(1000, FsmState.idle),
          _frame(2000, FsmState.armed),
        ]),
        isEmpty,
      );
    });

    test('repeated transitions emit one marker each', () {
      final frames = [
        _frame(0, FsmState.armed),
        _frame(1000, FsmState.ascent),
        _frame(2000, FsmState.armed),
        _frame(3000, FsmState.ascent),
        _frame(4000, FsmState.apogee),
      ];
      final events = detectFlightEvents(frames);
      expect(events.map((e) => e.type), [
        FlightEventType.launch,
        FlightEventType.launch,
        FlightEventType.apogee,
      ]);
      expect(events.map((e) => e.positionMs), [1000, 3000, 4000]);
    });

    test('non-nominal jumps are ignored', () {
      final frames = [
        _frame(0, FsmState.armed),
        _frame(1000, FsmState.apogee), // skipped ascent — not a launch
        _frame(2000, FsmState.landed), // skipped parachute — not a touchdown
        _frame(3000, FsmState.debugUnlocked),
        _frame(4000, FsmState.debugLocked),
      ];
      expect(detectFlightEvents(frames), isEmpty);
    });

    test('connector event tables drive detection', () {
      const defs = [
        ConnectorEventDef(label: 'Liftoff', fromStateId: 1, toStateId: 2),
      ];
      final events = detectFlightEvents(
        [_frame(0, FsmState.armed), _frame(100, FsmState.ascent)],
        eventDefs: defs,
      );
      expect(events, hasLength(1));
      expect(events.single.label, 'Liftoff');
      expect(events.single.transitionLabel, 'Armed → Ascent');
      // The same id pair maps into the nominal style table.
      expect(events.single.type, FlightEventType.launch);

      // Transitions outside the table are ignored.
      expect(
        detectFlightEvents(
          [_frame(0, FsmState.ascent), _frame(100, FsmState.apogee)],
          eventDefs: defs,
        ),
        isEmpty,
      );
    });

    test('multi-transition events fire on any listed jump', () {
      const defs = [
        ConnectorEventDef(
          label: 'Apogee',
          fromStateId: 2,
          toStateId: 3,
          additionalTransitions: [ConnectorTransition(2, 4)],
        ),
      ];
      // Direct ascent→parachute jump (firmware without an apogee state).
      final events = detectFlightEvents(
        [_frame(0, FsmState.ascent), _frame(100, FsmState.parachute)],
        eventDefs: defs,
      );
      expect(events, hasLength(1));
      expect(events.single.label, 'Apogee');
      expect(events.single.type, FlightEventType.apogee);
      expect(events.single.transitionLabel, 'Ascent → Parachute');
    });

    test('connector-specific transitions surface untyped', () {
      const defs = [
        ConnectorEventDef(label: 'Bench', fromStateId: 6, toStateId: 7),
      ];
      final events = detectFlightEvents(
        [_frame(0, FsmState.debugUnlocked), _frame(100, FsmState.debugLocked)],
        eventDefs: defs,
      );
      expect(events, hasLength(1));
      expect(events.single.type, isNull);
      expect(events.single.label, 'Bench');
      // The fallback style still renders untyped events.
      expect(flightEventStyleOf(events.single.type).color().a,
          greaterThan(0));
    });
  });

  group('placeFlightEvents', () {
    // Track geometry mirroring the pinned timeline slider: the thumb
    // travels from 24 to width - 24.
    const width = 800.0;
    const inset = 24.0;
    const travel = width - 2 * inset;

    FlightEvent at(int ms, [FlightEventType? type = FlightEventType.launch]) =>
        FlightEvent(
          type: type,
          label: type?.label ?? 'Custom',
          transitionLabel: type?.transitionLabel ?? '? → ?',
          frameIndex: 0,
          positionMs: ms,
          receivedAtMs: ms,
        );

    List<PlacedFlightEvent> place(List<FlightEvent> events, int duration) =>
        placeFlightEvents(
          events,
          duration,
          widthPx: width,
          trackLeftPx: inset,
          trackWidthPx: travel,
        );

    test('single event sits on the exact thumb position', () {
      final placed = place([at(1000)], 4000);
      expect(placed, hasLength(1));
      expect(placed.single.xPx, inset + 0.25 * travel);
      expect(placed.single.dyPx, 0);
    });

    test('endpoints map to the thumb travel ends, not the widget edges', () {
      final placed = place([at(0), at(4000)], 4000);
      expect(placed[0].xPx, inset);
      expect(placed[1].xPx, inset + travel);
      expect(placed.map((p) => p.dyPx), [0, 0]);
    });

    test('distant events share the on-track lane', () {
      final placed = place([at(0), at(2000), at(4000)], 4000);
      expect(placed.map((p) => p.dyPx), [0, 0, 0]);
    });

    test('colliding events spread into lanes keeping exact x', () {
      final placed = place([
        at(2000, FlightEventType.launch),
        at(2001, FlightEventType.apogee),
        at(2002, FlightEventType.parachute),
      ], 4000);
      // Same horizontal pixel to within a pixel, one lane each.
      final xs = placed.map((p) => p.xPx);
      expect(xs.reduce(math.max) - xs.reduce(math.min), lessThan(1));
      expect(placed.map((p) => p.dyPx), [0, 18, -18]);
    });

    test('every dot pair clears the minimum centre distance', () {
      final placed = place([at(1000), at(1001), at(1002), at(3000)], 4000);
      const minDist = flightEventDotDiameterPx + 2;
      for (var i = 0; i < placed.length; i++) {
        for (var j = i + 1; j < placed.length; j++) {
          final dx = (placed[i].xPx - placed[j].xPx).abs();
          final dy = (placed[i].dyPx - placed[j].dyPx).abs();
          expect(
            math.sqrt(dx * dx + dy * dy),
            greaterThanOrEqualTo(minDist - 1e-9),
          );
        }
      }
    });

    test('overflow past maxLanes shares the last lane', () {
      final placed = place([at(1000), at(1000), at(1000), at(1000)], 4000);
      expect(placed.map((p) => p.dyPx), [0, 18, -18, -18]);
    });

    test('degenerate inputs yield nothing', () {
      expect(place([], 4000), isEmpty);
      expect(place([at(100)], 0), isEmpty);
      expect(
        placeFlightEvents(
          [at(100)],
          4000,
          widthPx: 0,
          trackLeftPx: inset,
          trackWidthPx: travel,
        ),
        isEmpty,
      );
      expect(
        placeFlightEvents(
          [at(100)],
          4000,
          widthPx: width,
          trackLeftPx: inset,
          trackWidthPx: 0,
        ),
        isEmpty,
      );
    });

    test('out-of-range positions clamp to the travel ends', () {
      final placed = placeFlightEvents(
        [
          const FlightEvent(
            type: FlightEventType.launch,
            label: 'Launch',
            transitionLabel: 'Armed → Ascent',
            frameIndex: 0,
            positionMs: -50,
            receivedAtMs: -50,
          ),
          const FlightEvent(
            type: FlightEventType.touchdown,
            label: 'Touchdown',
            transitionLabel: 'Parachute → Landed',
            frameIndex: 1,
            positionMs: 99999,
            receivedAtMs: 99999,
          ),
        ],
        4000,
        widthPx: width,
        trackLeftPx: inset,
        trackWidthPx: travel,
      );
      expect(placed[0].xPx, inset);
      expect(placed[1].xPx, inset + travel);
    });
  });

  group('flight event definitions', () {
    test('every type names its nominal transition with a subtitle', () {
      expect(FlightEventType.launch.transitionLabel, 'Armed → Ascent');
      expect(FlightEventType.apogee.transitionLabel, 'Ascent → Apogee');
      expect(FlightEventType.parachute.transitionLabel, 'Apogee → Parachute');
      expect(FlightEventType.touchdown.transitionLabel, 'Parachute → Landed');
    });

    test('detection is driven by the type table', () {
      // Every table entry fires on exactly its own transition.
      for (final type in FlightEventType.values) {
        final events = detectFlightEvents([
          _frame(0, type.from),
          _frame(100, type.to),
        ]);
        expect(events.map((e) => e.type), [type]);
        expect(events.single.positionMs, 100);
        expect(events.single.receivedAtMs, 100);
      }
    });

    test('style table covers every type with distinct icons', () {
      final icons = <IconData>{};
      for (final type in FlightEventType.values) {
        final style = flightEventStyleOf(type);
        expect(style.color().a, greaterThan(0));
        expect(icons.add(style.icon), isTrue, reason: type.name);
      }
    });
  });

  group('replayFlightEventsProvider', () {
    test('derives markers from the loaded replay frames', () {
      final container = ProviderContainer(
        overrides: [
          replayProvider.overrideWith(
            () => _StubReplay(
              ReplayState(
                filePath: 'flight.bin',
                durationMs: 4000,
                frames: [
                  _frame(0, FsmState.armed),
                  _frame(1000, FsmState.ascent),
                  _frame(2000, FsmState.apogee),
                  _frame(3000, FsmState.parachute),
                  _frame(4000, FsmState.landed),
                ],
              ),
            ),
          ),
        ],
      );
      try {
        final events = container.read(replayFlightEventsProvider);
        expect(events.map((e) => e.type), [
          FlightEventType.launch,
          FlightEventType.apogee,
          FlightEventType.parachute,
          FlightEventType.touchdown,
        ]);
      } finally {
        container.dispose();
      }
    });
  });

  group('ReplayTimeline markers', () {
    Future<void> pumpBar(
      WidgetTester tester,
      _StubReplay stub, {
      double width = 800,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [replayProvider.overrideWith(() => stub)],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: width,
                height: 52,
                child: const PlaybackBar(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder seekMarkers() => find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message?.contains('tap to seek') ?? false),
    );

    testWidgets('markers seek to their event on tap', (tester) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'flight.bin',
          positionMs: 4000,
          durationMs: 4000,
          frames: [
            _frame(0, FsmState.armed),
            _frame(1000, FsmState.ascent),
            _frame(2000, FsmState.apogee),
            _frame(3000, FsmState.parachute),
            _frame(4000, FsmState.landed),
          ],
        ),
      );
      await pumpBar(tester, stub);

      expect(seekMarkers(), findsNWidgets(4));
      expect(find.byTooltip('Launch at 0:01 — tap to seek'), findsOneWidget);
      expect(find.byTooltip('Touchdown at 0:04 — tap to seek'), findsOneWidget);

      await tester.tap(find.byTooltip('Apogee at 0:02 — tap to seek'));
      await tester.pump();
      expect(stub.sought, 2000);
    });

    testWidgets('no markers without transitions', (tester) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'pad.bin',
          durationMs: 2000,
          frames: [
            _frame(0, FsmState.idle),
            _frame(1000, FsmState.armed),
            _frame(2000, FsmState.armed),
          ],
        ),
      );
      await pumpBar(tester, stub);

      expect(seekMarkers(), findsNothing);
      // The scrub slider itself is still there.
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('repeated launches show one marker each', (tester) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'bench.bin',
          durationMs: 3000,
          frames: [
            _frame(0, FsmState.armed),
            _frame(1000, FsmState.ascent),
            _frame(2000, FsmState.armed),
            _frame(3000, FsmState.ascent),
          ],
        ),
      );
      await pumpBar(tester, stub);

      expect(seekMarkers(), findsNWidgets(2));
      await tester.tap(find.byTooltip('Launch at 0:03 — tap to seek'));
      await tester.pump();
      expect(stub.sought, 3000);
    });

    testWidgets('clustered markers spread out and stay tappable', (
      tester,
    ) async {
      // Three transitions within 20 ms: on a 600 px bar their true
      // positions fall inside one pixel, so without lanes only the topmost
      // marker would ever receive taps.
      final stub = _StubReplay(
        ReplayState(
          filePath: 'cluster.bin',
          positionMs: 4000,
          durationMs: 4000,
          frames: [
            _frame(0, FsmState.armed),
            _frame(2000, FsmState.ascent),
            _frame(2010, FsmState.apogee),
            _frame(2020, FsmState.parachute),
            _frame(4000, FsmState.landed),
          ],
        ),
      );
      await pumpBar(tester, stub, width: 600);

      expect(seekMarkers(), findsNWidgets(4));

      await tester.tap(find.byTooltip('Launch at 0:02 — tap to seek'));
      await tester.pump();
      expect(stub.sought, 2000);

      await tester.tap(find.byTooltip('Apogee at 0:02 — tap to seek'));
      await tester.pump();
      expect(stub.sought, 2010);

      await tester.tap(find.byTooltip('Parachute at 0:02 — tap to seek'));
      await tester.pump();
      expect(stub.sought, 2020);
    });

    testWidgets('loop button toggles looping without seeking', (tester) async {
      final stub = _StubReplay(
        ReplayState(filePath: 'loop.bin', durationMs: 2000, frames: const []),
      );
      await pumpBar(tester, stub);

      expect(
        find.byTooltip('Loop off — tap to replay in a loop'),
        findsOneWidget,
      );
      await tester.tap(
        find.byTooltip('Loop off — tap to replay in a loop'),
      );
      await tester.pump();
      expect(stub.state.loopEnabled, isTrue);
      expect(stub.sought, isNull);
      expect(
        find.byTooltip(
          'Loop on — replay restarts at the end (tap for play-once)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('transport tooltip advertises the Space shortcut', (
      tester,
    ) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'space.bin',
          playing: false,
          durationMs: 2000,
          frames: const [],
        ),
      );
      await pumpBar(tester, stub);
      expect(find.byTooltip('Play (Space/K)'), findsOneWidget);
    });

    testWidgets('stepper buttons call the controller with their step', (
      tester,
    ) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'steps.bin',
          positionMs: 1000,
          durationMs: 4000,
          frames: const [],
        ),
      );
      await pumpBar(tester, stub);

      await tester.tap(find.byTooltip('Previous packet (,)'));
      expect(stub.steppedPacket, -1);
      await tester.tap(find.byTooltip('Next packet (.)'));
      expect(stub.steppedPacket, 1);
      await tester.tap(find.byTooltip('Back 1 second (J)'));
      expect(stub.steppedMs, -1000);
      await tester.tap(find.byTooltip('Forward 1 second (L)'));
      expect(stub.steppedMs, 1000);
      await tester.tap(find.byTooltip('Previous event or start (Ctrl+J)'));
      expect(stub.steppedEvent?.$1, -1);
      await tester.tap(find.byTooltip('Next event or end (Ctrl+L)'));
      expect(stub.steppedEvent?.$1, 1);
    });

    testWidgets('backward steppers disable at the recording start', (
      tester,
    ) async {
      IconButton button(String tooltip) => tester.widget<IconButton>(
            find.ancestor(
              of: find.byTooltip(tooltip),
              matching: find.byType(IconButton),
            ),
          );

      final start = _StubReplay(
        ReplayState(
          filePath: 'start.bin',
          positionMs: 0,
          durationMs: 4000,
          frames: const [],
        ),
      );
      await pumpBar(tester, start);
      expect(button('Previous packet (,)').onPressed, isNull);
      expect(button('Back 1 second (J)').onPressed, isNull);
      expect(button('Previous event or start (Ctrl+J)').onPressed, isNull);
      expect(button('Next packet (.)').onPressed, isNotNull);
      expect(button('Forward 1 second (L)').onPressed, isNotNull);
      expect(button('Next event or end (Ctrl+L)').onPressed, isNotNull);
    });

    testWidgets('forward steppers disable at the recording end', (
      tester,
    ) async {
      IconButton button(String tooltip) => tester.widget<IconButton>(
            find.ancestor(
              of: find.byTooltip(tooltip),
              matching: find.byType(IconButton),
            ),
          );

      final end = _StubReplay(
        ReplayState(
          filePath: 'end.bin',
          positionMs: 4000,
          durationMs: 4000,
          frames: const [],
        ),
      );
      await pumpBar(tester, end);
      expect(button('Previous packet (,)').onPressed, isNotNull);
      expect(button('Back 1 second (J)').onPressed, isNotNull);
      expect(button('Previous event or start (Ctrl+J)').onPressed, isNotNull);
      expect(button('Next packet (.)').onPressed, isNull);
      expect(button('Forward 1 second (L)').onPressed, isNull);
      expect(button('Next event or end (Ctrl+L)').onPressed, isNull);
    });
  });
}

class _StubReplay extends ReplayController {
  final ReplayState initial;

  int? sought;
  int? steppedPacket;
  int? steppedMs;
  (int, int)? steppedEvent;

  _StubReplay(this.initial);

  @override
  ReplayState build() => initial;

  @override
  void seek(int positionMs) {
    sought = positionMs;
    state = state.copyWith(positionMs: positionMs);
  }

  @override
  void stepPacket(int direction) {
    steppedPacket = direction;
  }

  @override
  void stepTime(int deltaMs) {
    steppedMs = deltaMs;
  }

  @override
  void stepEvent(int direction, List<FlightEvent> events) {
    steppedEvent = (direction, events.length);
  }

  @override
  void pause() {}
}
