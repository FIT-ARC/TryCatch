import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import './app_colors.dart';

/// Builds the global theme ("Precision Light" / dark companion, Material 3).
///
/// All colors resolve through [AppColors], so the same builder serves both
/// modes — callers rebuild [MaterialApp] when [AppThemeMode] flips.
/// Pointer cursor for every enabled interactive control, basic arrow when
/// disabled. Shared across all button / toggle / slider themes so no
/// clickable widget is left with the default arrow.
WidgetStateProperty<MouseCursor> get _clickableCursor =>
    WidgetStateProperty.resolveWith<MouseCursor>(
      (states) => states.contains(WidgetState.disabled)
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
    );

ThemeData buildAppTheme({bool dark = false}) {
  final scheme = dark
      ? ColorScheme.dark(
          primary: AppColors.primary,
          onPrimary: AppColors.primaryForeground,
          secondary: AppColors.muted,
          onSecondary: AppColors.foreground,
          surface: AppColors.card,
          onSurface: AppColors.foreground,
          surfaceContainerHighest: AppColors.muted,
          error: AppColors.destructive,
          onError: AppColors.primaryForeground,
          outline: AppColors.border,
          outlineVariant: AppColors.border,
        )
      : ColorScheme.light(
          primary: AppColors.primary,
          onPrimary: AppColors.primaryForeground,
          secondary: AppColors.muted,
          onSecondary: AppColors.foreground,
          surface: AppColors.card,
          onSurface: AppColors.foreground,
          surfaceContainerHighest: AppColors.muted,
          error: AppColors.destructive,
          onError: AppColors.primaryForeground,
          outline: AppColors.border,
          outlineVariant: AppColors.border,
        );

  final base =
      (dark
              ? ThemeData.dark(useMaterial3: true)
              : ThemeData.light(useMaterial3: true))
          .copyWith(
            colorScheme: scheme,
            scaffoldBackgroundColor: AppColors.background,
            splashFactory: InkSplash.splashFactory,
            splashColor: AppColors.pinkDeep.withValues(alpha: 0.05),
            highlightColor: AppColors.foreground.withValues(alpha: 0.04),
            dividerTheme: DividerThemeData(
              color: AppColors.border,
              thickness: 1,
              space: 1,
            ),
            textTheme: _buildTextTheme(),
            textSelectionTheme: TextSelectionThemeData(
              cursorColor: AppColors.pinkDeep,
              selectionColor: AppColors.primary.withValues(alpha: 0.16),
              selectionHandleColor: AppColors.pinkDeep,
            ),
            cardTheme: CardThemeData(
              color: AppColors.card,
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppDimens.radius),
                side: BorderSide(color: AppColors.border),
              ),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: AppColors.card,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppDimens.radius),
                side: BorderSide(color: AppColors.border),
              ),
              titleTextStyle: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
              contentTextStyle: TextStyle(
                fontSize: 13.5,
                color: AppColors.foreground,
                height: 1.45,
              ),
            ),
            appBarTheme: AppBarTheme(
              backgroundColor: AppColors.card,
              foregroundColor: AppColors.foreground,
              elevation: 0,
              scrolledUnderElevation: 0,
              centerTitle: false,
              systemOverlayStyle: dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark,
            ),
            tooltipTheme: TooltipThemeData(
              decoration: BoxDecoration(
                color: AppColors.foreground,
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              ),
              textStyle: TextStyle(color: AppColors.card, fontSize: 12),
              waitDuration: const Duration(milliseconds: 400),
            ),
            inputDecorationTheme: InputDecorationTheme(
              isDense: true,
              filled: true,
              fillColor: AppColors.card,
              hintStyle: TextStyle(color: AppColors.faint),
              labelStyle: TextStyle(color: AppColors.mutedForeground),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                borderSide: BorderSide(color: AppColors.strongBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                borderSide: BorderSide(color: AppColors.pinkDeep, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                borderSide: BorderSide(color: AppColors.destructive),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                borderSide: BorderSide(
                  color: AppColors.destructive,
                  width: 1.5,
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.primaryForeground,
                textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                visualDensity: VisualDensity.compact,
              ).copyWith(mouseCursor: _clickableCursor),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ).copyWith(mouseCursor: _clickableCursor),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.foreground,
                backgroundColor: AppColors.card,
                side: BorderSide(color: AppColors.strongBorder),
                textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                visualDensity: VisualDensity.compact,
              ).copyWith(mouseCursor: _clickableCursor),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: AppColors.pinkDeep,
                textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                visualDensity: VisualDensity.compact,
              ).copyWith(mouseCursor: _clickableCursor),
            ),
            iconButtonTheme: IconButtonThemeData(
              style: IconButton.styleFrom(
                foregroundColor: AppColors.foreground,
                visualDensity: VisualDensity.compact,
              ).copyWith(mouseCursor: _clickableCursor),
            ),
            menuButtonTheme: MenuButtonThemeData(
              style: MenuItemButton.styleFrom().copyWith(
                mouseCursor: _clickableCursor,
              ),
            ),
            segmentedButtonTheme: SegmentedButtonThemeData(
              style: ButtonStyle(mouseCursor: _clickableCursor),
            ),
            chipTheme: ChipThemeData(
              backgroundColor: AppColors.muted,
              selectedColor: AppColors.pinkSoft,
              showCheckmark: false,
              labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              side: BorderSide(color: AppColors.border),
              shape: StadiumBorder(),
            ),
            switchTheme: SwitchThemeData(
              mouseCursor: _clickableCursor,
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.primaryForeground
                    : AppColors.mutedForeground,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.primary
                    : AppColors.strongBorder,
              ),
            ),
            checkboxTheme: CheckboxThemeData(
              mouseCursor: _clickableCursor,
              side: BorderSide(color: AppColors.strongBorder),
              fillColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.primary
                    : Colors.transparent,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              visualDensity: VisualDensity.compact,
            ),
            radioTheme: RadioThemeData(mouseCursor: _clickableCursor),
            dropdownMenuTheme: DropdownMenuThemeData(
              textStyle: TextStyle(fontSize: 13, color: AppColors.foreground),
              inputDecorationTheme: InputDecorationTheme(
                isDense: true,
                filled: true,
                fillColor: AppColors.card,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(AppDimens.radiusSmall),
                  ),
                  borderSide: BorderSide(color: AppColors.strongBorder),
                ),
              ),
            ),
            menuTheme: MenuThemeData(
              style: MenuStyle(
                backgroundColor: WidgetStatePropertyAll(AppColors.card),
                surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
                elevation: WidgetStatePropertyAll(6),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppDimens.radius),
                    side: BorderSide(color: AppColors.border),
                  ),
                ),
              ),
            ),
            popupMenuTheme: PopupMenuThemeData(
              color: AppColors.card,
              surfaceTintColor: Colors.transparent,
              elevation: 6,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppDimens.radius),
                side: BorderSide(color: AppColors.border),
              ),
              textStyle: TextStyle(fontSize: 13, color: AppColors.foreground),
            ),
            sliderTheme: SliderThemeData(
              mouseCursor: _clickableCursor,
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.strongBorder,
              thumbColor: AppColors.primary,
              overlayColor: AppColors.primary.withValues(alpha: 0.12),
            ),
            progressIndicatorTheme: ProgressIndicatorThemeData(
              color: AppColors.primary,
              linearTrackColor: AppColors.border,
            ),
            scrollbarTheme: ScrollbarThemeData(
              thickness: WidgetStatePropertyAll(8),
              thumbVisibility: WidgetStatePropertyAll(false),
              radius: Radius.circular(4),
            ),
          );

  return base;
}

/// Compact, high-legibility type scale for dense ground-station UIs.
/// Built fresh on every theme build: colors resolve the active palette at
/// theme-build time (a top-level `final` would freeze launch-mode colors).
TextTheme _buildTextTheme() => TextTheme(
  displaySmall: TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
    letterSpacing: -0.5,
  ),
  headlineMedium: TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
    letterSpacing: -0.3,
  ),
  titleLarge: TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
  ),
  titleMedium: TextStyle(
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
  ),
  titleSmall: TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
  ),
  bodyLarge: TextStyle(fontSize: 15, color: AppColors.foreground),
  bodyMedium: TextStyle(fontSize: 13.5, color: AppColors.foreground),
  bodySmall: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
  labelLarge: TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
  ),
  labelMedium: TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    color: AppColors.foreground,
  ),
  labelSmall: TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w500,
    color: AppColors.mutedForeground,
    letterSpacing: 0.3,
  ),
);
