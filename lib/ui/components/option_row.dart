import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// One selectable option row: compact bordered row with a leading radio,
/// single-line title + subtitle, and a check holding the trailing slot
/// when selected (same box either way, so tapping never shifts heights).
///
/// Shared by the connector picker and the launch-site picker so both
/// selectors read as kin. Extra per-row actions (edit/remove) go in
/// [actions], after the check slot.
class OptionRow extends StatelessWidget {
  final bool selected;
  final VoidCallback? onTap;

  /// Radio value; the parent must provide the matching `RadioGroup`.
  /// Null hides the radio (manage rows, where tapping edits instead).
  final String? radioValue;

  final String title;
  final String subtitle;

  /// Subtitle voice; defaults to muted prose (site rows pass mono coords).
  final TextStyle? subtitleStyle;

  final List<Widget> actions;

  const OptionRow({
    super.key,
    required this.selected,
    required this.onTap,
    required this.radioValue,
    required this.title,
    required this.subtitle,
    this.subtitleStyle,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
            border: Border.all(
              // Same width in both states: color + tint + check carry the
              // selection, so tapping never shifts row heights.
              color: selected ? AppColors.primary : AppColors.border,
              width: 1,
            ),
            color: selected
                ? AppColors.primary.withValues(alpha: 0.06)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              if (radioValue != null)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Radio<String>(
                    value: radioValue!,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                )
              else
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Icon(Icons.flag_outlined,
                      size: 16, color: AppColors.mutedForeground),
                ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleStyle ??
                          TextStyle(
                              fontSize: 11.5,
                              color: AppColors.mutedForeground),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Opacity(
                opacity: selected ? 1.0 : 0.0,
                child: Icon(
                  Icons.check,
                  size: 16,
                  color: AppColors.primary,
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}
