import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/format.dart';
import 'package:trycatch/foundation/time/rate_series.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/components/link_stats_button.dart';

/// Pumps the top-bar link-stats button with stubbed streams.
///
/// [status] defaults to disconnected: the button must report live data
/// regardless of connection state.
Future<void> _pumpButton(
  WidgetTester tester, {
  SerialWorkerStatus status = const SerialWorkerStatus(),
  Stream<LinkStats>? linkStats,
  Stream<TelemetryFrame>? packets,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serialStatusProvider.overrideWith((ref) => Stream.value(status)),
        linkStatsStreamProvider.overrideWith(
          (ref) => linkStats ?? const Stream.empty(),
        ),
        telemetryStreamProvider.overrideWith(
          (ref) => packets ?? const Stream.empty(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: LinkStatsButton())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('LinkStatsButton (connection-agnostic)', () {
    testWidgets('shows unknown B/s + stale age while disconnected',
        (tester) async {
      final t1 = DateTime.now().millisecondsSinceEpoch - 10000;
      await _pumpButton(
        tester,
        linkStats: Stream.fromIterable([
          LinkStats(timestampMs: t1),
          LinkStats(
            timestampMs: t1 + 1000,
            totalBytes: 700,
            matchedBytes: 550,
            garbageBytes: 150,
            matchedPackets: 10,
          ),
        ]),
      );

      expect(find.text('OFFLINE'), findsNothing);
      expect(find.textContaining(RegExp(r'ago')), findsOneWidget);
      expect(find.text('150 B/s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows live pkt/s with fresh snapshots', (tester) async {
      final t1 = DateTime.now().millisecondsSinceEpoch - 1000;
      await _pumpButton(
        tester,
        linkStats: Stream.fromIterable([
          LinkStats(timestampMs: t1),
          LinkStats(
            timestampMs: t1 + 500,
            totalBytes: 1100,
            matchedBytes: 1000,
            matchedPackets: 20,
          ),
        ]),
      );
      expect(find.textContaining(RegExp(r'\d+\.\d pkt/s')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('RateSeries label', () {
    test('no data before the first snapshot', () {
      expect(RateSeries().label(nowMs: 0), 'no data');
    });

    test('live rate while flowing, age past the 2 s window', () {
      final series = RateSeries();
      series.addSnapshot(const LinkStats(timestampMs: 1000, totalBytes: 100));
      series.addSnapshot(const LinkStats(
        timestampMs: 1500,
        totalBytes: 700,
        matchedBytes: 600,
        matchedPackets: 3,
      ));
      expect(series.label(nowMs: 1500), '6.0 pkt/s');
      expect(series.label(nowMs: 5500), '4.0 s ago');
    });
  });

  group('dead link signals red', () {
    testWidgets('silent link reads red no matter the congestion',
        (tester) async {
      // Quiet frequency (150 B/s is mere activity) but stale link:
      // the pill must signal the dead link, not the quiet channel.
      final t1 = DateTime.now().millisecondsSinceEpoch - 10000;
      await _pumpButton(
        tester,
        linkStats: Stream.fromIterable([
          LinkStats(timestampMs: t1),
          LinkStats(
            timestampMs: t1 + 1000,
            totalBytes: 700,
            matchedBytes: 550,
            garbageBytes: 150,
            matchedPackets: 10,
          ),
        ]),
      );

      expect(find.text('OFFLINE'), findsNothing);
      expect(find.text('150 B/s'), findsOneWidget);
      expect(find.textContaining(RegExp(r'ago')), findsOneWidget);

      final pills = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border is Border,
        ),
      );
      expect(pills, hasLength(1));
      final border =
          (pills.single.decoration as BoxDecoration).border as Border;
      expect(
        border.top.color,
        AppColors.destructive.withValues(alpha: 0.5),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('linkStateColor', () {
    test('neutral before any data ever arrived', () {
      expect(
        linkStateColor(
            unmatchedBps: 0, packetsLive: false, hasData: false),
        AppColors.mutedForeground,
      );
    });

    test('dead link is red no matter the congestion', () {
      for (final bps in [0.0, 150.0, 600.0]) {
        expect(
          linkStateColor(
              unmatchedBps: bps, packetsLive: false, hasData: true),
          AppColors.destructive,
          reason: 'unmatched $bps B/s',
        );
      }
    });

    test('live link follows the congestion verdict', () {
      expect(
        linkStateColor(unmatchedBps: 0, packetsLive: true, hasData: true),
        AppColors.success,
      );
      expect(
        linkStateColor(
            unmatchedBps: 150, packetsLive: true, hasData: true),
        AppColors.warning,
      );
      expect(
        linkStateColor(
            unmatchedBps: 600, packetsLive: true, hasData: true),
        AppColors.destructive,
      );
    });
  });

  group('formatPacketAge', () {
    test('formats ms / seconds / minutes', () {
      expect(formatPacketAge(const Duration(milliseconds: 850)),
          '850 ms ago');
      expect(
          formatPacketAge(const Duration(milliseconds: 3200)), '3.2 s ago');
      expect(formatPacketAge(const Duration(seconds: 125)), '2m 5s ago');
    });
  });
}
