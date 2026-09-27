import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/foundation/ids.dart';
import 'package:trycatch/foundation/time/decimation.dart';
import 'package:trycatch/foundation/time/rate_series.dart';
import 'package:trycatch/foundation/time/time_series.dart';
import 'package:serial/serial.dart';

class _Pt {
  final int ts;
  final double v;
  _Pt(this.ts, this.v);
}

void main() {
  test('Ids unique with prefix', () {
    Ids.resetForTests();
    final a = Ids.next('tile');
    final b = Ids.next('tile');
    expect(a, isNot(b));
    expect(a.startsWith('tile_'), isTrue);
  });

  test('RingTimeSeries chronological + slice + split', () {
    final s = RingTimeSeries<_Pt>(8, (p) => p.ts);
    for (var i = 0; i < 5; i++) {
      s.push(_Pt(i * 100, i.toDouble()));
    }
    expect(s.oldest(0).ts, 0);
    expect(s.newest(0).ts, 400);
    expect(s.slice(100, 300).length, 3);
    final (played, future) = s.splitAt(200);
    expect(played.length, 3);
    expect(future.length, 2);
    s.clear();
    expect(s.isEmpty, isTrue);
  });

  test('decimate extremes keeps spike, stride keeps tip', () {
    final s = RingTimeSeries<_Pt>(16, (p) => p.ts);
    for (var i = 0; i < 8; i++) {
      s.push(_Pt(i, i == 4 ? 100 : 1));
    }
    final ext = decimate<_Pt>(s, (p) => p.ts ~/ 4, [(p) => p.v], maxPoints: 400);
    expect(ext.any((p) => p.v == 100), isTrue);
    final str = decimate<_Pt>(s, (p) => p.ts, [(p) => p.v],
        maxPoints: 4, mode: Decimation.strideStable);
    expect(str.first.ts, 0);
    expect(str.last.ts, 7);
    expect(str.length <= 5, isTrue);
  });

  test('RateSeries rewind clears, label fresh/stale', () {
    final r = RateSeries();
    expect(r.label(), 'no data');
    r.addSnapshot(const LinkStats(timestampMs: 1000, totalBytes: 100));
    r.addSnapshot(const LinkStats(
        timestampMs: 2000,
        totalBytes: 1100,
        matchedBytes: 1000,
        matchedPackets: 10));
    expect(r.isNotEmpty, isTrue);
    expect(r.label(nowMs: 2100).contains('pkt/s'), isTrue);
    expect(r.label(nowMs: 6000).contains('ago'), isTrue);
    r.addSnapshot(const LinkStats(timestampMs: 3000, totalBytes: 10));
    expect(r.isEmpty, isTrue);
    r.clear();
    expect(r.isEmpty, isTrue);
  });

  test('windowed mean hides slice-phase flicker', () {
    // Measured MOCK cadence: alternating 187 ms / 1-pkt and 313 ms / 4-pkt
    // slices at a true 10 Hz. Instantaneous slices read 5.3 / 12.8.
    final r = RateSeries();
    var t = 1000;
    var total = 0;
    var matched = 0;
    var packets = 0;
    r.addSnapshot(LinkStats(timestampMs: t, totalBytes: total));
    for (var i = 0; i < 8; i++) {
      final dt = i.isEven ? 187 : 313;
      final dpk = i.isEven ? 1 : 4;
      t += dt;
      total += dpk * 55;
      matched += dpk * 55;
      packets += dpk;
      r.addSnapshot(LinkStats(
        timestampMs: t,
        totalBytes: total,
        matchedBytes: matched,
        matchedPackets: packets,
      ));
    }
    // Instantaneous still flickers slice to slice...
    expect(r.latest!.packetRate, greaterThan(12.0));
    // ...but the displayed windowed mean sits at the true rate.
    final label = r.label(nowMs: t);
    final shown = double.parse(label.split(' ').first);
    expect(shown, inInclusiveRange(9.0, 11.0));
  });
}
