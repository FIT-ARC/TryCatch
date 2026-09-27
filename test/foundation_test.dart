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
}
