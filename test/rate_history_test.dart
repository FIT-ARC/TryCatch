import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/foundation/time/rate_series.dart';

void main() {
  LinkStats snap(int time, int packets) => LinkStats(
    timestampMs: time,
    totalBytes: packets * 55,
    matchedBytes: packets * 55,
    matchedPackets: packets,
  );
  test('no data and clear are idempotent', () {
    final rates = RateSeries();
    expect(rates.label(nowMs: 0), 'no data');
    rates.addSnapshot(snap(0, 0));
    rates.addSnapshot(snap(500, 100));
    expect(rates.latest!.packetRate, 200);
    rates.clear();
    rates.clear();
    expect(rates.latest, isNull);
    expect(rates.label(nowMs: 1000), 'no data');
  });
  test('silence shows last-packet age, reconnect preserves history', () {
    final rates = RateSeries();
    rates.addSnapshot(snap(0, 0));
    rates.addSnapshot(snap(1000, 100));
    expect(rates.label(nowMs: 1000), '100.0 pkt/s');
    expect(rates.label(nowMs: 4000), '3.0 s ago');
    expect(rates.addSnapshot(snap(5000, 0)), isNull);
    expect(rates.length, 1);
    expect(rates.label(nowMs: 5000), '4.0 s ago');
  });
}
