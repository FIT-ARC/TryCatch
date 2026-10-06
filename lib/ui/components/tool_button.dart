import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Small square overlay button for map/3D corners (camera modes, zoom,
/// follow, layer toggles). Shared so every overlay button looks and behaves
/// the same.
class ToolFab extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const ToolFab({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: active ? AppColors.primary : AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          side: BorderSide(
            color: active ? AppColors.fixedTransparent : AppColors.border,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          child: Tooltip(
            message: tooltip,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                icon,
                size: 16,
                color: active
                    ? AppColors.primaryForeground
                    : AppColors.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
