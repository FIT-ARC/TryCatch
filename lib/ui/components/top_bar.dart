import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../state/replay_controller.dart';
import '../../theme/app_colors.dart';
import './brand_mark.dart';
import './link_stats_button.dart';
import './playback_bar.dart';
import './recording_controls.dart';
import '../screens/router.dart';
import './serial_controls.dart';

/// Always-visible top chrome ("Precision Light").
///
/// Three zones: brand (taps home to Dashboard) · centered live controls
/// (port + link icon, combined stats, record) · quick nav (dashboard,
/// recorded flights, settings). The side zones share one fixed width so the
/// center group sits on the true screen center. Channel health opens from
/// the stats pill.
/// While a replay is active the live zones collapse into the playback
/// controls and the nav slot becomes the close-replay action — same spot,
/// same size — so the center stays balanced and the close target never
/// moves. Closing a replay returns to the recorded-flights screen. The app
/// is not listening to the radio during a replay.
class TopBar extends ConsumerWidget {
  const TopBar({super.key});

  /// Width of the left/right side zones. Both sides share this width so the
  /// centered live controls stay on the true screen center: the brand mark
  /// (logo + wordmark + tagline, ~250px with padding in the test font) is
  /// much wider than the quick-nav pill, which would otherwise push the
  /// center group's midpoint right of center.
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
          // the quick-nav pill occupies when live.
          SizedBox(
            width: sideWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: replaying ? _CloseReplayButton() : _QuickNav(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Replay close action living in the nav slot while a replay is active.
///
/// Same right padding via the parent so the close target sits where the nav
/// pill was. Disabled while the recording is
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

/// Top-right quick nav: dashboard, recorded flights + settings in one pill.
///
/// Same chrome as the port and link pills (32px, bordered, 8px radius) but
/// narrower — three icon segments joined by hairlines. Channel health opens
/// from the stats pill. Replaced by [_CloseReplayButton] during replay.
class _QuickNav extends ConsumerWidget {
  const _QuickNav();

  static const double _segmentWidth = 36;
  static const List<AppScreen> _screens = [
    AppScreen.dashboard,
    AppScreen.flights,
    AppScreen.settings,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appRouterProvider);

    return Container(
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(color: AppColors.strongBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _screens.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 18,
                color: AppColors.border,
              ),
            _NavSegment(
              screen: _screens[i],
              selected: _screens[i] == current,
              first: i == 0,
              last: i == _screens.length - 1,
              onTap: () =>
                  ref.read(appRouterProvider.notifier).go(_screens[i]),
            ),
          ],
        ],
      ),
    );
  }
}

/// One icon segment of the quick-nav pill, with a selected tint.
class _NavSegment extends StatelessWidget {
  final AppScreen screen;
  final bool selected;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  const _NavSegment({
    required this.screen,
    required this.selected,
    required this.first,
    required this.last,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _QuickNav._segmentWidth,
      height: 32,
      child: Tooltip(
        message: screen.label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: _segmentRadius(),
                color: selected
                    ? AppColors.pinkSoft
                    : Colors.transparent,
              ),
              child: Icon(
                screen.icon,
                size: 18,
                color: selected
                    ? AppColors.pinkDeep
                    : AppColors.mutedForeground,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Square inner corners against the dividers, rounded outer corners
  // matching the pill.
  BorderRadius _segmentRadius() {
    return BorderRadius.horizontal(
      left: first ? Radius.circular(AppDimens.radiusSmall) : Radius.zero,
      right: last ? Radius.circular(AppDimens.radiusSmall) : Radius.zero,
    );
  }
}
