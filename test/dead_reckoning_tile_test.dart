import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dead_reckoning/dead_reckoning.dart' show DeadReckoningPosition;
import 'package:serial/serial.dart' show FrameFlags, TelemetryFrame;
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/launch_site_store.dart' show LaunchSite;
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tile_registry.dart';
import 'package:trycatch/ui/tiles/dead_reckoning_tile.dart';
import 'package:trycatch/ui/tiles/stats_tile.dart';

/// The position split: `stats` is GPS-only, `dead_reckoning` owns the
/// estimate — disabled during replay, hidden behind a link-nominal
/// placeholder while packets flow, visible only on packet loss (with drift
/// from the launch site and the 3D distance from the last known position).
/// Both tiles share the centred readout with copy + QR actions.
class _FreshStore extends TelemetryStore {
  @override
  TelemetryState build() {
    final history = RingBuffer<TelemetryFrame>(10);
    final frame = TelemetryFrame(
      receivedAtMs: DateTime.now().millisecondsSinceEpoch,
      sequence: 1,
      flags: FrameFlags.gpsFix,
      latitude: 50.0755,
      longitude: 14.4378,
      baroAltitude: 403,
    );
    history.push(frame);
    return TelemetryState(
      history: history,
      deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
      latest: frame,
      deadReckoning: const DeadReckoningPosition(
          latitude: 50.0755, longitude: 14.4378, altitude: 403, atMs: 0),
    );
  }
}

class _StaleStore extends TelemetryStore {
  @override
  TelemetryState build() {
    final history = RingBuffer<TelemetryFrame>(10);
    const frame = TelemetryFrame(
      receivedAtMs: 0, // long silent link → packet loss
      sequence: 1,
      flags: FrameFlags.gpsFix,
      latitude: 50.0755,
      longitude: 14.4378,
      baroAltitude: 403,
    );
    history.push(frame);
    return TelemetryState(
      history: history,
      deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
      latest: frame,
      deadReckoning: const DeadReckoningPosition(
          latitude: 50.0800, longitude: 14.4400, altitude: 405, atMs: 0),
    );
  }
}

class _ActiveReplay extends ReplayController {
  @override
  ReplayState build() => const ReplayState(filePath: 'test.bin');
}

const _pad = LaunchSite(
  name: 'Pad',
  latitude: 50.0755,
  longitude: 14.4378,
  altitudeMsl: 400,
);

Future<void> _pump(
  WidgetTester tester,
  Widget tile, {
  required TelemetryStore Function() store,
  bool replaying = false,
  LaunchSite? site,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        telemetryStoreProvider.overrideWith(store),
        if (replaying) replayProvider.overrideWith(_ActiveReplay.new),
        effectiveLaunchSiteProvider.overrideWith((ref) => site),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 300, child: tile),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('dead reckoning tile is registered alongside the GPS position tile',
      () {
    expect(TileRegistry.byId('dead_reckoning'), isNotNull);
    expect(TileRegistry.byId('stats')?.title, 'GPS position');
  });

  testWidgets('healthy link hides the estimate behind link-nominal',
      (tester) async {
    await _pump(tester, const DeadReckoningTile(), store: _FreshStore.new);
    expect(find.text('LINK HEALTHY'), findsOneWidget);
    expect(find.text('EXTRAPOLATING'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'packet loss reveals the estimate with drift and 3D distance',
      (tester) async {
    await _pump(tester, const DeadReckoningTile(),
        store: _StaleStore.new, site: _pad);
    // No status pill: the tile only renders while extrapolating, so one
    // would state the obvious.
    expect(find.text('EXTRAPOLATING'), findsNothing);
    // Projected fix differs from the last GPS fix — it is the estimate.
    expect(find.text('50.08000°, 14.44000°'), findsOneWidget);
    expect(find.textContaining('Altitude 405 m'), findsOneWidget);
    expect(find.textContaining('Drift'), findsOneWidget);
    expect(find.textContaining('from last known position'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR action opens a scannable coordinates dialog',
      (tester) async {
    await _pump(tester, const DeadReckoningTile(),
        store: _StaleStore.new, site: _pad);
    await tester.tap(find.byIcon(Icons.qr_code_2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('50.080000, 14.440000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replay disables dead reckoning', (tester) async {
    await _pump(tester, const DeadReckoningTile(),
        store: _FreshStore.new, replaying: true);
    expect(find.text('Disabled during replay'), findsOneWidget);
    expect(find.text('LINK HEALTHY'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GPS tile shows fix status, altitude and drift', (tester) async {
    await _pump(tester, const StatsTile(),
        store: _FreshStore.new, site: _pad);
    expect(find.text('Fix'), findsOneWidget);
    expect(find.text('50.07550°, 14.43780°'), findsOneWidget);
    expect(find.text('Altitude 403 m · Drift 0 m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GPS tile flags a stale link without repeating the title',
      (tester) async {
    await _pump(tester, const StatsTile(),
        store: _StaleStore.new, site: _pad);
    expect(find.text('Fix · Stale'), findsOneWidget);
    expect(find.textContaining('GPS'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
