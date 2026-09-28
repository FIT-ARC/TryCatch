import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/components/tool_button.dart';
import 'package:trycatch/ui/screens/tile_leaf_scope.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_shell.dart';

/// Locks the shared 3D flight shell contract: the camera-mode picker shows
/// one button per mode (none for the fixed onboard lens), the persisted leaf
/// mode is restored once, and mode changes are reported back to the leaf.
void main() {
  testWidgets('shell shows one button per picker mode, none when fixed',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Flight3dShell(
            painter: _DummyPainter(),
            mode: FlightCameraMode.chase,
            onMode: (_) {},
            onZoomBy: (_) {},
            onResetZoom: () {},
            onOrbit: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
        find.byType(ToolFab), findsNWidgets(FlightCameraMode.values.length));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Flight3dShell(
            painter: _DummyPainter(),
            modes: const [],
            onZoomBy: (_) {},
            onResetZoom: () {},
            onOrbit: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ToolFab), findsNothing);
  });

  testWidgets('shell restores the persisted leaf mode once', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TileLeafScope.fromSettings(
              tileId: 'leaf1',
              settings: const {leafCameraModeKey: 'orbit'},
              onCameraMode: (_) {},
              child: const _ShellHarness(),
            ),
          ),
        ),
      ),
    );
    final state =
        tester.state<_ShellHarnessState>(find.byType(_ShellHarness));
    expect(state.mode, FlightCameraMode.orbit);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('shell reports mode changes back to the leaf', (tester) async {
    final reported = <FlightCameraMode>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TileLeafScope.fromSettings(
              tileId: 'leaf1',
              settings: const {},
              onCameraMode: reported.add,
              child: const _ShellHarness(),
            ),
          ),
        ),
      ),
    );
    final state =
        tester.state<_ShellHarnessState>(find.byType(_ShellHarness));
    expect(state.mode, FlightCameraMode.chase);

    state.setShellMode(FlightCameraMode.orbit);
    expect(reported, [FlightCameraMode.orbit]);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  test('onboard drag spin turns around the nose axis and wraps', () {
    expect(spinAfterDrag(0, 30), closeTo(348, 1e-9));
    expect(spinAfterDrag(348, -30), closeTo(0, 1e-9));
  });
}

class _DummyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ShellHarness extends ConsumerStatefulWidget {
  const _ShellHarness();

  @override
  ConsumerState<_ShellHarness> createState() => _ShellHarnessState();
}

class _ShellHarnessState extends ConsumerState<_ShellHarness>
    with Flight3dShellState {
  @override
  Widget build(BuildContext context) => const SizedBox();
}
