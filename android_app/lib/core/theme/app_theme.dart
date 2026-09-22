import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

/// Spacing/radius scale. Kept as named constants so no magic numbers end up
/// sprinkled through widgets (spec §66).
abstract final class Insets {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class Radii {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 18.0;
  static const pill = 999.0;
}

abstract final class AppTheme {
  static const systemOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  );

  static ThemeData build({bool tv = false}) {
    final scale = tv ? 1.25 : 1.0;
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.accent,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      splashFactory: InkSparkle.splashFactory,
    );

    TextStyle t(double size, FontWeight w, Color c, {double? height}) =>
        TextStyle(fontSize: size * scale, fontWeight: w, color: c, height: height);

    return base.copyWith(
      dividerColor: AppColors.divider,
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 0.5,
        space: 0.5,
      ),
      textTheme: base.textTheme.copyWith(
        displaySmall: t(30, FontWeight.w700, AppColors.textPrimary),
        headlineMedium: t(26, FontWeight.w700, AppColors.textPrimary),
        headlineSmall: t(22, FontWeight.w600, AppColors.textPrimary),
        titleLarge: t(18, FontWeight.w600, AppColors.textPrimary),
        titleMedium: t(16, FontWeight.w600, AppColors.textPrimary),
        bodyLarge: t(15, FontWeight.w400, AppColors.textPrimary, height: 1.35),
        bodyMedium: t(14, FontWeight.w400, AppColors.textSecondary, height: 1.35),
        bodySmall: t(12, FontWeight.w400, AppColors.textTertiary),
        labelLarge: t(14, FontWeight.w600, AppColors.textPrimary),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemOverlay,
        titleTextStyle: t(24, FontWeight.w700, AppColors.textPrimary),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          minimumSize: Size(0, 50 * scale),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
          textStyle: t(16, FontWeight.w600, Colors.white),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: t(15, FontWeight.w400, AppColors.textTertiary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.lg,
          vertical: Insets.lg,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.divider,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: t(14, FontWeight.w400, AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      ),
    );
  }
}
