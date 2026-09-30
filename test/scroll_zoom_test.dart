import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dead_reckoning/dead_reckoning.dart' show DeadReckoningPosition;
import 'package:serial/serial.dart' show TelemetryFrame;
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tiles/map_tile.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_shell.dart';
import 'package:trycatch/ui/tiles/shared/trackpad_zoom.dart'
    show scrollZoomFactor;

class _EmptyStore extends TelemetryStore {
  @override
  TelemetryState build() => TelemetryState(
        history: RingBuffer<TelemetryFrame>(10),
        deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
      );
}

/// Wheel-zoom regression tests: the map, the shared flight-3D shell (used
/// by the 3D Flight and Onboard camera tiles) and the rocket orientation
/// view must all respond to mouse-wheel scroll.
void main() {
  testWidgets('map tile zooms on wheel scroll', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryStoreProvider.overrideWith(_EmptyStore.new),
          effectiveLaunchSiteProvider.overrideWith((ref) => null),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 800, height: 600, child: MapTile()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    double zoom() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera
        .zoom;
    expect(zoom(), 15.0);

    final center = tester.getCenter(find.byType(MapTile));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -120)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(zoom(), greaterThan(15.0));

    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(zoom(), 15.0);
  });

  testWidgets('map tile zooms on trackpad swipe, not on pinch twice',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryStoreProvider.overrideWith(_EmptyStore.new),
          effectiveLaunchSiteProvider.overrideWith((ref) => null),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 800, height: 600, child: MapTile()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    double zoom() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera
        .zoom;
    final center = tester.getCenter(find.byType(MapTile));

    // Two-finger swipe up: per-update pan deltas, scale exactly 1.
    await tester.sendEventToBinding(PointerPanZoomStartEvent(position: center));
    for (var i = 0; i < 10; i++) {
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          position: center,
          panDelta: const Offset(0, -10),
          scale: 1.0,
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(PointerPanZoomEndEvent(position: center));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 100 px at the wheel velocity (0.005/px) = +0.5 zoom.
    expect(zoom(), closeTo(15.5, 0.01));

    // Pinch still zooms exactly once, via flutter_map's own pinch-zoom
    // (the wrapper skips any update carrying scale).
    await tester.sendEventToBinding(PointerPanZoomStartEvent(position: center));
    for (var i = 1; i <= 10; i++) {
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          position: center,
          scale: 1.0 + i * 0.05,
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(PointerPanZoomEndEvent(position: center));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(zoom(), greaterThan(15.5));
  });

  testWidgets('flight-3d shell forwards wheel zoom', (tester) async {
    final factors = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Flight3dShell(
            painter: _DummyPainter(),
            mode: FlightCameraMode.chase,
            onMode: (_) {},
            onZoomBy: factors.add,
            onResetZoom: () {},
            onOrbit: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(Flight3dShell));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -120)),
    );
    await tester.pump();
    expect(factors, [1.1]);

    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    expect(factors, [1.1, 1 / 1.1]);
  });

  testWidgets('flight-3d shell zooms (not orbits) on trackpad swipe',
      (tester) async {
    final factors = <double>[];
    final orbits = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Flight3dShell(
            painter: _DummyPainter(),
            mode: FlightCameraMode.chase,
            onMode: (_) {},
            onZoomBy: factors.add,
            onResetZoom: () {},
            onOrbit: orbits.add,
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(Flight3dShell));
    await tester.sendEventToBinding(PointerPanZoomStartEvent(position: center));
    for (var i = 0; i < 5; i++) {
      await tester.sendEventToBinding(
        PointerPanZoomUpdateEvent(
          position: center,
          panDelta: const Offset(0, -10),
          scale: 1.0,
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(PointerPanZoomEndEvent(position: center));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Swipe up zooms in every tick…
    expect(factors, hasLength(5));
    expect(factors.every((f) => f > 1.0), isTrue);
    // …and never tilts: the drag recognizer also sees the swipe, but the
    // shell suppresses orbit while a trackpad gesture is active.
    expect(orbits, isEmpty);
  });

  test('wheel/trackpad factor: one notch is x1.1, zero is neutral', () {
    expect(scrollZoomFactor(-120), closeTo(1.1, 1e-9));
    expect(scrollZoomFactor(120), closeTo(1 / 1.1, 1e-9));
    expect(scrollZoomFactor(0), 1.0);
  });
}

class _DummyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
