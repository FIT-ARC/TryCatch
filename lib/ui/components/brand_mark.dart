import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Brand mark: logo image + wordmark with the "ARC@FIT"
/// tagline as a monospace micro-label.
///
/// All colors resolve inside [build] (never cached) so theme flips repaint.
class BrandMark extends StatelessWidget {
  final bool compact;

  const BrandMark({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Image.asset(
            'assets/icon.png',
            width: 28,
            height: 28,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '{TryCatch}',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
                letterSpacing: -0.2,
              ),
            ),
            if (!compact)
              Text(
                'TESTING IN PRODUCTION',
                style: AppText.microLabel.copyWith(
                  fontSize: 8,
                  letterSpacing: 1.2,
                  color: AppColors.faint,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
