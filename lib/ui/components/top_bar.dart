import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../session/flight_reset.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import './brand_mark.dart';
import './link_stats_button.dart';
import './playback_bar.dart';
import './recording_controls.dart';
import '../screens/router.dart';
import './serial_controls.dart';

/// Always-visible top chrome ("Precision Light").
///
/// Three zones: brand · centered live controls (port + link icon, combined
/// stats, record) · menu. The side zones share one fixed width
/// so the center group sits on the true screen center. The center group keeps
/// fixed-width slots so nothing shifts when the link comes up or values
/// repaint. Reset lives in the menu. While a replay is active the live zones
/// collapse into the playback controls and the menu slot becomes the
/// close-replay action — same spot, same size — so the center stays
/// balanced and the close target never moves. Closing a replay returns to
/// the recorded-flights screen. The app is not listening to
/// the radio during a replay.
class TopBar extends ConsumerWidget {
  const TopBar({super.key});

  /// Width of the left/right side zones. Both sides share this width so the
  /// centered live controls stay on the true screen center: the brand mark
  /// (logo + wordmark + tagline, ~250px with padding in the test font) is
  /// much wider than the 44px menu button, which used to push the center
  /// group's midpoint right of center.
  static const double sideWidth = AppConfig.topBarSideWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final replaying = ref.watch(replayProvider).isActive;

    return Container(
      height: AppDimens.topBarHeight,
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // NOTE: intentionally non-const throughout this row — const
          // instances are identical across builds, so the framework skips
          // rebuilding the subtree and dynamic AppColors would freeze on
          // theme flips (this is what stuck the wordmark in one palette).
          // Fixed-width side zone: left half of the centering balance.
          SizedBox(
            width: sideWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ref
                        .read(appRouterProvider.notifier)
                        .go(AppScreen.dashboard),
                    child: Tooltip(
                      message: 'Back to Dashboard',
                      child: BrandMark(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (replaying)
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16),
                child: PlaybackBar(),
              ),
            )
          else
            // NOTE: intentionally non-const — const children would freeze
            // across dark-mode flips (AppColors resolves dynamically).
            Expanded(
              child: Align(
                alignment: Alignment.center,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SerialControls(),
                      SizedBox(width: 8),
                      LinkStatsButton(),
                      SizedBox(width: 8),
                      RecordingControls(),
                    ],
                  ),
                ),
              ),
            ),
          // Fixed-width side zone matching the brand side, so the Expanded
          // center above stays on the true screen center. During replay this
          // slot holds the close-replay action in the exact spot (and size)
          // the hamburger menu button occupies when live.
          SizedBox(
            width: sideWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: replaying ? _CloseReplayButton() : _NavMenu(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Replay close action living in the menu slot while a replay is active.
///
/// Pixel-identical placement and sizing to [_NavMenu]'s hamburger button
/// (44px, same right padding via the parent) so the close target never
/// moves from where the menu button was. Disabled while the recording is
/// still decoding: closing mid-decode races the pending async load (see
/// ReplayController.play generation guard).
class _CloseReplayButton extends ConsumerWidget {
  const _CloseReplayButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));
    return IconButton(
      onPressed: isLoading
          ? null
          : () {
              ref.read(replayProvider.notifier).stop();
              ref.read(appRouterProvider.notifier).go(AppScreen.flights);
            },
      icon: const Icon(Icons.close),
      iconSize: 24,
      tooltip: isLoading
          ? 'Loading flight…'
          : 'Close replay (back to recorded flights)',
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        ),
      ),
    );
  }
}

/// Top-right menu: app screens plus the flight reset action.
///
/// Reset lives here rather than as a bar icon so the top bar holds only
/// link + record controls — one menu for everything else.
///
/// Replaced by [_CloseReplayButton] during replay: the playback bar owns the
/// top bar while a replay is active, and resetting mid-replay would corrupt
/// the replay state.
class _NavMenu extends ConsumerWidget {
  const _NavMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appRouterProvider);
    final hasData = (ref.watch(telemetryStoreProvider).packetCount) > 0;
    // Resetting mid-replay would corrupt the replay state.
    final replaying = ref.watch(replayProvider).isActive;
    final canReset = hasData && !replaying;

    return MenuAnchor(
      style: const MenuStyle(
        minimumSize: WidgetStatePropertyAll(Size(216, 0)),
        maximumSize: WidgetStatePropertyAll(Size(260, double.infinity)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        ),
      ),
      builder: (context, controller, child) => IconButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.menu),
        iconSize: 24,
        tooltip: 'Menu',
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          ),
        ),
      ),
      menuChildren: [
        for (final screen in AppScreen.values)
          Builder(
            builder: (context) {
              final selected = screen == current;
              return MenuItemButton(
                leadingIcon: Icon(
                  screen.icon,
                  size: 18,
                  color: selected
                      ? AppColors.pinkDeep
                      : AppColors.mutedForeground,
                ),
                style: MenuItemButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: 0.1,
                  ),
                  foregroundColor: selected
                      ? AppColors.foreground
                      : AppColors.mutedForeground,
                  backgroundColor: selected ? AppColors.pinkSoft : null,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusSmall),
                  ),
                ),
                onPressed: () =>
                    ref.read(appRouterProvider.notifier).go(screen),
                child: Text(screen.label),
              );
            },
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Divider(height: 1),
        ),
        MenuItemButton(
          leadingIcon: Icon(
            Icons.restart_alt,
            size: 18,
            color:
                canReset ? AppColors.destructive : AppColors.mutedForeground,
          ),
          style: MenuItemButton.styleFrom(
            minimumSize: const Size.fromHeight(40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
            foregroundColor: canReset
                ? AppColors.destructive
                : AppColors.mutedForeground,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
            ),
          ),
          onPressed: canReset ? () => _confirmReset(context, ref) : null,
          child: const Text('Clear buffers…'),
        ),
      ],
    );
  }

  /// Clears the flight buffers via FlightReset: telemetry, commands,
  /// channel history (replay already excluded by canReset above).
  Future<void> _confirmReset(BuildContext context, WidgetRef ref) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear buffers?'),
        content: const Text(
          'This discards the current flight — track, max values and '
          'averages — and starts fresh. Recordings on disk are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.destructive),
            onPressed: () {
              // Drop focus first: yanking a focused subtree out from under
              // the engine while every tile flips to "waiting" at once.
              FocusManager.instance.primaryFocus?.unfocus();
              FlightReset.clearFlight(ref);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
