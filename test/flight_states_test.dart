import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
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

  group('segmentAt', () {
    // States: 1 for 0-9 s, 2 for 10-29 s, 4 after.
    List<TelemetryFrame> flight() => [
          for (var s = 0; s <= 40; s++)
            _frame(s * 1000, s < 10 ? 1 : (s < 30 ? 2 : 4)),
        ];

    test('resolves the run containing the playhead', () {
      final frames = flight();
      final mid = segmentAt(frames, 4500)!;
      expect(mid.stateId, 1);
      expect(mid.entryMs, 0);
      expect(mid.exitMs, 9000);
      final later = segmentAt(frames, 19500)!;
      expect(later.stateId, 2);
      expect(later.entryMs, 10000);
      expect(later.exitMs, 29000);
    });

    test('same position always yields the same segment', () {
      final frames = flight();
      final a = segmentAt(frames, 15000)!;
      final b = segmentAt(frames, 15000)!;
      expect(a.entryMs, b.entryMs);
      expect(a.exitMs, b.exitMs);
      expect(a.stateId, b.stateId);
    });

    test('before the first frame yields null, empty yields null', () {
      expect(segmentAt(flight(), -1000), isNull);
      expect(segmentAt(const [], 0), isNull);
    });
  });
}
