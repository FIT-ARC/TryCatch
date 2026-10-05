import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/ui/tiles/shared/replay_vsync.dart';

/// The vsync ticker mixin runs on every smoothed 3D tile. A wrong
/// `TickerProviderStateMixin` cast in it turned all of them red the moment
/// smoothing was enabled (the tiles mix in `SingleTickerProviderStateMixin`,
/// a sibling — not a subtype). This probe tile pins the wiring: it builds
/// the display clock exactly like the 3D tiles do.
void main() {
  group('ReplayVsync', () {
    testWidgets('ticker runs only while a smoothed replay plays',
        (tester) async {
      final stub = _VsyncStub(
        ReplayState(
          filePath: 'v.bin',
          playing: true,
          smoothingEnabled: true,
          positionMs: 1000,
          durationMs: 10000,
          positionWallMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final key = GlobalKey<_ProbeState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [replayProvider.overrideWith(() => stub)],
          child: MaterialApp(home: _ProbeTile(key: key)),
        ),
      );
      expect(key.currentState!.debugVsyncActive, isTrue);

      stub.state = stub.state.copyWith(playing: false);
      await tester.pump();
      expect(key.currentState!.debugVsyncActive, isFalse);

      stub.state =
          stub.state.copyWith(playing: true, smoothingEnabled: false);
      await tester.pump();
      expect(key.currentState!.debugVsyncActive, isFalse);

      stub.state =
          stub.state.copyWith(playing: true, smoothingEnabled: true);
      await tester.pump();
      expect(key.currentState!.debugVsyncActive, isTrue);
    });
  });
}

class _VsyncStub extends ReplayController {
  final ReplayState initial;

  _VsyncStub(this.initial);

  @override
  ReplayState build() => initial;
}

/// Minimal tile using the production mixin stack: `ConsumerState` +
/// `SingleTickerProviderStateMixin` + `ReplayVsync`, resolving the display
/// clock in `build` like the 3D tiles do.
class _ProbeTile extends ConsumerStatefulWidget {
  const _ProbeTile({super.key});

  @override
  ConsumerState<_ProbeTile> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_ProbeTile>
    with SingleTickerProviderStateMixin, ReplayVsync {
  @override
  Widget build(BuildContext context) {
    final replay = ref.watch(replayProvider);
    replayDisplayMs(replay);
    return const SizedBox();
  }
}
