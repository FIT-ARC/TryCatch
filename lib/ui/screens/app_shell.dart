import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../foundation/app_log.dart';
import '../../state/replay_controller.dart';
import './monitor_screen.dart';
import './recordings_screen.dart';
import './settings_screen.dart';
import './dashboard_screen.dart';
import './router.dart';
import '../components/live_bridge_relay.dart';
import '../components/serial_toast_bridge.dart';
import '../components/toast_overlay.dart';
import '../components/top_bar.dart';

/// Root layout: top bar on every screen + the active screen below it.
///
/// Screens live in an [IndexedStack] so switching is instant: every screen
/// stays mounted, and returning to a screen restores its state (map tiles,
/// channel-health history, scroll positions) instead of rebuilding the whole
/// subtree.
///
/// While a replay is active, video-player keybinds drive the transport from
/// any screen with focus (Space/K play, `,`/`.` packet, J/L ∓1 s,
/// Ctrl+J/L prev/next event). The binding lives here so key events bubble
/// from the focused control up through this ancestor.
/// Focused buttons and switches consume Space themselves via `ActivateIntent`
/// (inner Shortcuts win), so they never double-toggle the replay; text
/// fields handle typing keys as input, so those are guarded explicitly below.
/// Dialogs live in the overlay (outside this subtree) and never reach here.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screen = ref.watch(appRouterProvider);
    final replayActive = ref.watch(replayProvider.select((s) => s.isActive));

    // Switching screens drops text focus: a field left focused (e.g. after
    // a dialog closes onto another screen) would otherwise keep swallowing
    // every replay key with no visible cause.
    ref.listen(appRouterProvider, (previous, next) {
      if (previous != next) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });

    // Don't hijack typing: EditableText handles keys as text input, not
    // via Shortcuts, so an outer binding would also fire.
    bool isTyping() {
      final primary = FocusManager.instance.primaryFocus;
      final ctx = primary?.context;
      if (ctx == null) return false;
      var editing = ctx.widget is EditableText;
      if (!editing) {
        ctx.visitAncestorElements((e) {
          if (e.widget is EditableText) {
            editing = true;
            return false;
          }
          return true;
        });
      }
      return editing;
    }

    void Function() guarded(String what, void Function() action) {
      return () {
        // Debug-only breadcrumb: blocked keys are otherwise invisible
        // (no error, no action), which reads as "keybinds sometimes die".
        if (isTyping()) {
          AppLog.warn('Replay key ignored while typing ($what).');
          return;
        }
        action();
      };
    }

    final replay = ref.read(replayProvider.notifier);

    return CallbackShortcuts(
      bindings: {
        if (replayActive) ...{
          const SingleActivator(LogicalKeyboardKey.space):
              guarded('play/pause', replay.toggle),
          const SingleActivator(LogicalKeyboardKey.keyK):
              guarded('play/pause', replay.toggle),
          const SingleActivator(LogicalKeyboardKey.comma):
              guarded('prev packet', () => replay.stepPacket(-1)),
          const SingleActivator(LogicalKeyboardKey.period):
              guarded('next packet', () => replay.stepPacket(1)),
          const SingleActivator(LogicalKeyboardKey.keyJ):
              guarded('back 1 s', () => replay.stepTime(-1000)),
          const SingleActivator(LogicalKeyboardKey.keyL):
              guarded('forward 1 s', () => replay.stepTime(1000)),
          SingleActivator(LogicalKeyboardKey.keyJ, control: true):
              guarded('prev event', () => replay.stepEvent(
                  -1, ref.read(replayFlightEventsProvider))),
          SingleActivator(LogicalKeyboardKey.keyL, control: true):
              guarded('next event', () => replay.stepEvent(
                  1, ref.read(replayFlightEventsProvider))),
        },
      },
      child: Scaffold(
        body: Stack(
          children: [
            Column(
              children: [
                // NOTE: non-const on purpose — const children would not rebuild on
                // a dark-mode flip (AppColors resolves dynamically).
                TopBar(),
                Expanded(
                  child: IndexedStack(
                    index: screen.index,
                    children: [
                      DashboardScreen(),
                      RecordingsScreen(),
                      MonitorScreen(),
                      SettingsScreen(),
                    ],
                  ),
                ),
              ],
            ),
            // Headless: turns worker errors / disconnects / failed uplinks
            // into toasts (renders nothing itself).
            SerialToastBridge(),
            // Headless: forks live frames into the bridge isolate for the
            // read-only public output (renders nothing itself).
            LiveBridgeRelay(),
            // Floating error/warning cards over the workspace.
            ToastOverlay(),
          ],
        ),
      ),
    );
  }
}
