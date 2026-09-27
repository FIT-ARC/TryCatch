import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../session/feedback.dart';
import '../../theme/app_colors.dart';

/// Small copy-to-clipboard button with a toast confirmation.
class CopyButton extends ConsumerWidget {
  final String text;

  /// Tooltip + toast context (defaults to Google Maps paste format).
  final String formatName;

  /// Icon-only rendering for tight rows (same tap behavior + toast).
  final bool iconOnly;

  const CopyButton({
    super.key,
    required this.text,
    this.formatName = 'Google Maps format',
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Tooltip(
      message: 'Copy "$text" ($formatName)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            ref.successToast('Copied $text');
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: iconOnly ? 4 : 8,
              vertical: 3,
            ),
            child: iconOnly
                ? Icon(Icons.copy,
                    size: 13, color: AppColors.mutedForeground)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy,
                          size: 12, color: AppColors.mutedForeground),
                      SizedBox(width: 4),
                      Text(
                        'COPY',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
