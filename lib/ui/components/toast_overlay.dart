import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/toast_store.dart';
import '../../theme/app_colors.dart';

/// Floating toast stack rendered over the workspace (bottom-right),
/// sonner-style.
///
/// Shows the newest [ToastStore.maxVisible] cards, oldest on top and newest
/// at the bottom edge (like sonner's bottom-right placement). Cards animate
/// in with a slide-up + fade and out with a slide-down + fade + collapse,
/// while survivors glide to fill the gap — all via [AnimatedList], which the
/// overlay keeps in sync with [toastStoreProvider] (insert/remove per id
/// diff; consecutive-duplicate refreshes update the card in place).
/// Each card auto-dismisses ([ToastCard.dismissAfter] per severity) and has
/// a manual close button. Colors/icons follow the status palette;
/// intentionally non-const throughout so dark-mode flips repaint (see the
/// dark-mode const rule in HANDOFF).
class ToastOverlay extends ConsumerStatefulWidget {
  /// Enter motion (sonner springs in at ~400 ms).
  static const enterDuration = Duration(milliseconds: 350);

  /// Exit motion (sonner leaves faster than it arrives).
  static const exitDuration = Duration(milliseconds: 250);

  const ToastOverlay({super.key});

  @override
  ConsumerState<ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends ConsumerState<ToastOverlay> {
  final _listKey = GlobalKey<AnimatedListState>();

  /// Visible cards, oldest first — mirrors the store tail; the single
  /// source AnimatedList's item count is derived from.
  late List<ToastMessage> _shown;

  /// Newest-first tail of the store, capped to what fits on screen.
  static List<ToastMessage> visibleOf(List<ToastMessage> toasts) =>
      toasts.length > ToastStore.maxVisible
          ? toasts.sublist(toasts.length - ToastStore.maxVisible)
          : List.of(toasts);

  @override
  void initState() {
    super.initState();
    _shown = visibleOf(ref.read(toastStoreProvider));
  }

  /// Reconciles [_shown] (and the [AnimatedList]) with the store tail:
  /// removals high-to-low, then ordered inserts, then in-place content
  /// refreshes (dedupe bumps the timestamp without changing identity).
  void _sync(List<ToastMessage> next) {
    final list = _listKey.currentState;
    if (list == null) {
      _shown = next;
      return;
    }
    for (var i = _shown.length - 1; i >= 0; i--) {
      if (!next.any((t) => t.id == _shown[i].id)) {
        final removed = _shown.removeAt(i);
        list.removeItem(
          i,
          (context, animation) => _AnimatedToast(
            toast: removed,
            animation: animation,
          ),
          duration: ToastOverlay.exitDuration,
        );
      }
    }
    var pos = 0;
    for (final toast in next) {
      final at = _shown.indexWhere((t) => t.id == toast.id);
      if (at == -1) {
        _shown.insert(pos, toast);
        list.insertItem(pos, duration: ToastOverlay.enterDuration);
        pos++;
      } else {
        _shown[at] = toast;
        pos = at + 1;
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(toastStoreProvider, (_, next) => _sync(visibleOf(next)));
    // Always build the AnimatedList, even empty: the list state must exist
    // so later inserts have something to animate into (an empty list
    // renders zero-size). Returning a bare SizedBox when empty orphans
    // every subsequent insert.
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: AnimatedList(
            key: _listKey,
            initialItemCount: _shown.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, index, animation) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _AnimatedToast(
                toast: _shown[index],
                animation: animation,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One card with sonner motion: slide-up + fade on the way in, slide-down +
/// fade + collapse on the way out. The same tween serves both directions —
/// [AnimatedList] runs the animation 0→1 for inserts and 1→0 for removals.
class _AnimatedToast extends StatelessWidget {
  final ToastMessage toast;
  final Animation<double> animation;

  const _AnimatedToast({required this.toast, required this.animation});

  @override
  Widget build(BuildContext context) {
    final curved =
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return SizeTransition(
      sizeFactor: curved,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.5),
            end: Offset.zero,
          ).animate(curved),
          child: ToastCard(key: ValueKey(toast.id), toast: toast),
        ),
      ),
    );
  }
}

/// Single toast card: severity icon + title/message + close button with a
/// colored leading edge.
class ToastCard extends ConsumerStatefulWidget {
  final ToastMessage toast;

  const ToastCard({super.key, required this.toast});

  /// Auto-dismiss delay per severity (errors linger, info flashes).
  static Duration dismissAfter(ToastSeverity severity) => switch (severity) {
        ToastSeverity.error => Duration(seconds: 6),
        ToastSeverity.warning => Duration(seconds: 5),
        _ => Duration(seconds: 4),
      };

  @override
  ConsumerState<ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends ConsumerState<ToastCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(ToastCard.dismissAfter(widget.toast.severity), () {
      if (mounted) ref.read(toastStoreProvider.notifier).dismiss(widget.toast.id);
    });
  }

  @override
  void didUpdateWidget(covariant ToastCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refreshed (deduped) toast restarts its countdown.
    if (oldWidget.toast.timestampMs != widget.toast.timestampMs) {
      _timer?.cancel();
      _timer = Timer(ToastCard.dismissAfter(widget.toast.severity), () {
        if (mounted) {
          ref.read(toastStoreProvider.notifier).dismiss(widget.toast.id);
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.toast;
    final accent = switch (toast.severity) {
      ToastSeverity.error => AppColors.destructive,
      ToastSeverity.warning => AppColors.warning,
      ToastSeverity.success => AppColors.success,
      ToastSeverity.info => AppColors.info,
    };
    final icon = switch (toast.severity) {
      ToastSeverity.error => Icons.error_outline,
      ToastSeverity.warning => Icons.warning_amber_outlined,
      ToastSeverity.success => Icons.check_circle_outline,
      ToastSeverity.info => Icons.info_outline,
    };
    return Material(
      color: AppColors.card,
      elevation: 6,
      borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          border: Border.all(color: AppColors.border),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(AppDimens.radiusSmall),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(icon, size: 20, color: accent),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (toast.title != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            toast.title!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.foreground,
                            ),
                          ),
                        ),
                      Text(
                        toast.message,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: AppColors.foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: () => ref
                    .read(toastStoreProvider.notifier)
                    .dismiss(toast.id),
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Dismiss',
                style: IconButton.styleFrom(
                  minimumSize: const Size(32, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
