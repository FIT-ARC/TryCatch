import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Small rounded-rect badge with a status dot — used for connection state,
/// recording indicator, FSM badge, hall sensor state, etc.
///
/// Precision-Light style: monospace uppercase label, soft wash background and
/// a 1px border derived from the status color.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool pulsing;
  final bool outlined;

  /// Fixed height so pills line up with buttons in chrome rows; `null`
  /// shrink-wraps.
  final double? height;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.pulsing = false,
    this.outlined = false,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      alignment: height == null ? null : Alignment.center,
      decoration: BoxDecoration(
        color: outlined
            ? AppColors.fixedTransparent
            : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: outlined
              ? color.withValues(alpha: 0.55)
              : color.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: color, pulsing: pulsing),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: AppText.mono.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: color == AppColors.mutedForeground
                  ? AppColors.mutedForeground
                  : Color.lerp(color, AppColors.foreground, 0.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final Color color;
  final bool pulsing;

  const _Dot({required this.color, required this.pulsing});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Dot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.pulsing
            ? Color.lerp(widget.color, AppColors.card, _controller.value * 0.6)
            : widget.color,
      ),
    );
  }
}
