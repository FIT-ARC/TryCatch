import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/services/time_correction.dart';

void main() {
  group('enforceMonotonic', () {
    test('backward scan keeps latest occurrence per grid value', () {
      final out = enforceMonotonic(const [
        TimeAnchor(0, 1000),
        TimeAnchor(0, 2000),
        TimeAnchor(0, 3000),
        TimeAnchor(100, 4000),
      ]);
      expect(out, const [TimeAnchor(0, 3000), TimeAnchor(100, 4000)]);
    });

    test('drops inverted pairs', () {
      final out = enforceMonotonic(const [
        TimeAnchor(0, 1000),
        TimeAnchor(200, 2000),
        TimeAnchor(100, 3000),
        TimeAnchor(300, 4000),
      ]);
      expect(out, const [
        TimeAnchor(0, 1000),
        TimeAnchor(100, 3000),
        TimeAnchor(300, 4000),
      ]);
    });
  });

  group('mapGridToTrue', () {
    const anchors = [
      TimeAnchor(0, 10000),
      TimeAnchor(1000, 11000),
      TimeAnchor(2000, 14000),
    ];

    test('interpolates within segments', () {
      expect(mapGridToTrue(anchors, 500), 10500);
      expect(mapGridToTrue(anchors, 1500), 12500);
    });

    test('clamps below the first anchor', () {
      expect(mapGridToTrue(anchors, -100), 10000);
    });

    test('extrapolates past the last anchor at the final slope', () {
      // Final slope is 3 ms/ms.
      expect(mapGridToTrue(anchors, 3000), 17000);
    });
  });

  group('ogFsmToMock', () {
    test('mirrors the original converter', () {
      expect(ogFsmToMock('00'), 1);
      expect(ogFsmToMock('01'), 1);
      expect(ogFsmToMock('02'), 2);
      expect(ogFsmToMock('04'), 4);
      expect(ogFsmToMock('03'), isNull);
      expect(ogFsmToMock('F0'), isNull);
    });
  });

  group('selectPadPrologue', () {
    CsvSiteSample row(int t, String fsm, double alt) => CsvSiteSample(
          trueMs: t,
          latitude: 49.797,
          longitude: 16.697,
          baroAltitude: alt,
          batteryVoltage: 4.0,
          fsm: fsm,
          rollDeg: 0,
          pitchDeg: 0,
        );

    test('keeps idle pad rows before liftoff only', () {
      final rows = [
        row(1000, '00', 1),
        row(2000, '01', 2),
        row(3000, '02', 5), // stray transition: out
        row(4000, '04', 100), // airborne: out
        row(5000, '00', 1), // after liftoff: out
      ];
      final prologue = selectPadPrologue(rows, 4500);
      expect(prologue.map((r) => r.trueMs), [1000, 2000]);
    });
  });

  group('padFrameFrom', () {
    test('takes position/time/battery from the row, dynamics from signature',
        () {
      const signature = TelemetryFrame(
        flags: 3,
        gpsAltitude: 403,
        accelX: -0.2,
        accelY: -0.2,
        accelZ: 3.24,
        gyroX: 4.0,
        heading: 90,
        yaw: 45,
        hallRaw: 2154,
      );
      const row = CsvSiteSample(
        trueMs: 123456789,
        latitude: 49.8,
        longitude: 16.7,
        baroAltitude: 2.5,
        batteryVoltage: 4.01,
        fsm: '01',
        rollDeg: 1.5,
        pitchDeg: -2.5,
      );
      final frame = padFrameFrom(
          row: row, padSignature: signature, sequence: 7, fsmStateId: 1);
      expect(frame.receivedAtMs, 123456789);
      expect(frame.sequence, 7);
      expect(frame.latitude, 49.8);
      expect(frame.baroAltitude, 2.5);
      expect(frame.batteryVoltage, 4.01);
      expect(frame.roll, 1.5);
      expect(frame.pitch, -2.5);
      expect(frame.velocityDown, 0);
      expect(frame.accelZ, 3.24);
      expect(frame.heading, 90);
      expect(frame.hallRaw, 2154);
      expect(frame.fsmStateId, 1);
    });
  });
}
