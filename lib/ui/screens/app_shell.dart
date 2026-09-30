import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// While a replay is active, Space toggles pause/play (video-player style).
/// The binding lives here so it works from any screen with focus: key events
/// bubble from the focused control up through this ancestor. Focused buttons
/// and switches consume Space themselves via `ActivateIntent` (inner
/// Shortcuts win), so they never double-toggle the replay; text fields
/// handle Space as typed input, so those are guarded explicitly below.
/// Dialogs live in the overlay (outside this subtree) and never reach here.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screen = ref.watch(appRouterProvider);
    final replayActive = ref.watch(replayProvider.select((s) => s.isActive));

    return CallbackShortcuts(
      bindings: {
        if (replayActive)
          const SingleActivator(LogicalKeyboardKey.space): () {
            // Don't hijack typing: EditableText handles Space as text
            // input, not via Shortcuts, so an outer binding would also fire.
            final primary = FocusManager.instance.primaryFocus;
            final ctx = primary?.context;
            if (ctx != null) {
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
              if (editing) return;
            }
            ref.read(replayProvider.notifier).toggle();
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
