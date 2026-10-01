import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Shared input look for everything on the settings page: live-sharing
/// fields plus the site add/edit/import dialogs. One dense outlined
/// field with a mono value, so every settings input reads as kin.
///
/// Locked inputs use `readOnly` + `canRequestFocus: false` instead of
/// `enabled: false` (which would restyle them), wrapped in an `Opacity`
/// dim: same layout, only grayish.
InputDecoration settingsFieldDecoration(BuildContext context, String label) {
  return const InputDecoration()
      .applyDefaults(Theme.of(context).inputDecorationTheme)
      .copyWith(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 9,
        ),
        labelText: label,
      );
}

/// Shared value style for settings inputs.
TextStyle get settingsFieldStyle => AppText.mono.copyWith(fontSize: 12);
