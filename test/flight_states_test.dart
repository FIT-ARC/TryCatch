import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/flight_events.dart';
import 'package:trycatch/core/flight_states.dart';

TelemetryFrame _frame(int ms, int fsm, [double alt = 0]) => TelemetryFrame(
      receivedAtMs: ms,
      fsmStateId: fsm,
      baroAltitude: alt,
    );

void main() {
  group('findStateEntryMs', () {
    test('single-state history yields the oldest frame, not zero span', () {
      final frames = [_frame(1000, 1), _frame(2000, 1), _frame(3000, 1)];
      expect(findStateEntryMs(frames, 1), 1000);
    });

    test('finds the transition boundary', () {
      final frames = [_frame(1000, 1), _frame(2000, 2), _frame(3000, 2)];
      expect(findStateEntryMs(frames, 2), 1000);
    });

    test('empty input yields zero', () {
      expect(findStateEntryMs(const [], 1), 0);
    });
  });

  group('stateSegmentProgress', () {
    // States: 1 for 0-10 s, 2 for 10-30 s, 4 after.
    List<TelemetryFrame> flight() => [
          for (var s = 0; s <= 40; s++)
            _frame(s * 1000, s < 10 ? 1 : (s < 30 ? 2 : 4)),
        ];

    test('fraction through the run containing the playhead', () {
      final frames = flight();
      expect(stateSegmentProgress(frames, 4500, 1), closeTo(0.5, 1e-9));
      expect(stateSegmentProgress(frames, 19500, 2), closeTo(0.5, 1e-9));
      expect(stateSegmentProgress(frames, 0, 1), 0);
    });

    test('unknown state and empty input yield zero', () {
      final frames = flight();
      expect(stateSegmentProgress(frames, 5000, 9), 0);
      expect(stateSegmentProgress(const [], 0, 1), 0);
    });
  });

  group('detectDataDrivenEvents', () {
    test('apogee at peak altitude, touchdown on return', () {
      final frames = [
        for (var s = 0; s <= 20; s++)
          _frame(s * 1000, 4, s <= 10 ? s * 10.0 : (20 - s) * 10.0),
      ];
      final events = detectDataDrivenEvents(frames);
      expect(events.map((e) => e.type),
          [FlightEventType.apogee, FlightEventType.touchdown]);
      expect(events[0].positionMs, 10000);
      expect(events[1].positionMs, 20000);
    });

    test('flat bench yields nothing', () {
      final frames = [for (var s = 0; s <= 20; s++) _frame(s * 1000, 4, 1.0)];
      expect(detectDataDrivenEvents(frames), isEmpty);
    });

    test('flight that never lands yields apogee only', () {
      final frames = [
        for (var s = 0; s <= 20; s++) _frame(s * 1000, 2, s * 10.0),
      ];
      final events = detectDataDrivenEvents(frames);
      expect(events.map((e) => e.type), [FlightEventType.apogee]);
    });
  });
}
