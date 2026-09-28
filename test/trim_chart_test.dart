import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/flight_events.dart';
import 'package:trycatch/services/flight_trim.dart' show AltitudePoint;
import 'package:trycatch/ui/components/flight_event_style.dart';
import 'package:trycatch/ui/screens/trim_chart.dart';

TelemetryFrame _frame(int atMs, FsmState state) =>
    TelemetryFrame(receivedAtMs: atMs, fsmStateId: state.id);

/// Nominal flight: launch @2 s, apogee @3 s, parachute @4 s, touchdown @5 s.
List<FlightEvent> _nominalEvents() => detectFlightEvents([
      _frame(0, FsmState.idle),
      _frame(1000, FsmState.armed),
      _frame(2000, FsmState.ascent),
      _frame(3000, FsmState.apogee),
      _frame(4000, FsmState.parachute),
      _frame(5000, FsmState.landed),
    ]);

const _ramp = [
  AltitudePoint(0, 0),
  AltitudePoint(1000, 10),
  AltitudePoint(2000, 25),
  AltitudePoint(3000, 45),
  AltitudePoint(4000, 30),
  AltitudePoint(5000, 5),
];

Future<void> _pumpChart(
  WidgetTester tester, {
  List<AltitudePoint> values = _ramp,
  List<FlightEvent>? events,
  int totalMs = 5000,
  int startMs = 0,
  int endMs = 5000,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 110,
          child: TrimChart(
            values: values,
            events: events ?? _nominalEvents(),
            totalMs: totalMs,
            startMs: startMs,
            endMs: endMs,
            color: Colors.pink,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _dots({bool? dimmed}) => find.byWidgetPredicate(
      (w) => w is FlightEventDot && (dimmed == null || w.dimmed == dimmed),
    );

void main() {
  group('TrimChart event markers', () {
    testWidgets('one marker per flight event, on the kept slice', (
      tester,
    ) async {
      await _pumpChart(tester);

      expect(_dots(), findsNWidgets(4));
      expect(_dots(dimmed: true), findsNothing);
      expect(find.byTooltip('Launch at 0:02'), findsOneWidget);
      expect(find.byTooltip('Apogee at 0:03'), findsOneWidget);
      expect(find.byTooltip('Parachute at 0:04'), findsOneWidget);
      expect(find.byTooltip('Touchdown at 0:05'), findsOneWidget);
    });

    testWidgets('markers outside the kept slice dim and say so', (
      tester,
    ) async {
      await _pumpChart(tester, startMs: 3000, endMs: 5000);

      expect(_dots(), findsNWidgets(4));
      expect(_dots(dimmed: false), findsNWidgets(3));
      expect(_dots(dimmed: true), findsOneWidget);
      expect(
        find.byTooltip('Launch at 0:02 — outside kept slice'),
        findsOneWidget,
      );
      expect(find.byTooltip('Apogee at 0:03'), findsOneWidget);
    });

    testWidgets('no markers without events', (tester) async {
      await _pumpChart(tester, events: const []);

      expect(_dots(), findsNothing);
    });

    testWidgets('clustered events all stay rendered', (tester) async {
      final events = detectFlightEvents([
        _frame(0, FsmState.armed),
        _frame(2000, FsmState.ascent),
        _frame(2010, FsmState.apogee),
        _frame(2020, FsmState.parachute),
        _frame(5000, FsmState.landed),
      ]);
      await _pumpChart(tester, events: events);

      expect(_dots(), findsNWidgets(4));
      expect(find.byTooltip('Launch at 0:02'), findsOneWidget);
      expect(find.byTooltip('Apogee at 0:02'), findsOneWidget);
      expect(find.byTooltip('Parachute at 0:02'), findsOneWidget);
    });
  });
}
