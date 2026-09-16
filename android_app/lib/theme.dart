import 'package:flutter/material.dart';

/// Colours taken from the reference screens: near-black surfaces, soft grey
/// cards with a hairline border, and a pink-red accent for everything active.
class AppColors {
  static const bg = Color(0xFF121212);
  static const bg2 = Color(0xFF1C1C1E);   // cards
  static const bg3 = Color(0xFF2A2A2D);   // raised / pressed
  static const border = Color(0xFF2E2E31);
  static const accent = Color(0xFFEF3F66); // pink-red: selected tab, highlights
  static const accent2 = Color(0xFFE53945); // chip red
  static const text = Color(0xFFF5F5F7);
  static const textDim = Color(0xFF9A9AA0);
  static const danger = Color(0xFFEF4444);
  static const success = Color(0xFF34C759);

  // Settings tiles
  static const tileCyan = Color(0xFF4FC9DB);
  static const tileOrange = Color(0xFFF29A4A);
  static const tileIndigo = Color(0xFF6D78F2);
  static const tileGreen = Color(0xFF4CC46A);
  static const tileRed = Color(0xFFE5383B);
  static const tilePurple = Color(0xFF9B6DF2);
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent2,
      surface: AppColors.bg2,
      error: AppColors.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(color: AppColors.text, fontSize: 22, fontWeight: FontWeight.w700),
    ),
    textTheme: base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bg2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
      hintStyle: const TextStyle(color: AppColors.textDim),
      labelStyle: const TextStyle(color: AppColors.textDim),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
    dividerColor: AppColors.border,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.bg3,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: AppColors.bg2, surfaceTintColor: Colors.transparent),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : AppColors.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.accent : AppColors.bg3),
    ),
  );
}

/// Section title + one-line description, as used across Profile and Downloads.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const SectionHeader(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!, style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
        ],
      ],
    );
  }
}

BoxDecoration cardDecoration({double radius = 18, Color? color}) => BoxDecoration(
      color: color ?? AppColors.bg2,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: AppColors.border),
    );
