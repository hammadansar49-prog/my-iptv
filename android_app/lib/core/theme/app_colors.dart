import 'package:flutter/material.dart';

/// Palette taken from the supplied design screenshots (spec §39): a true-black
/// background with slightly raised dark-grey surfaces and one crimson accent.
abstract final class AppColors {
  static const background = Color(0xFF000000);

  /// Cards, list groups, the floating bottom bar.
  static const surface = Color(0xFF1B1B1D);
  static const surfaceHigh = Color(0xFF242427);

  /// Hairlines between grouped rows.
  static const divider = Color(0xFF2E2E31);

  static const accent = Color(0xFFF5104A);
  static const accentSoft = Color(0x33F5104A);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF9E9EA4);
  static const textTertiary = Color(0xFF6B6B70);

  static const success = Color(0xFF34C759);
  static const warning = Color(0xFFFF9F0A);
  static const danger = Color(0xFFFF3B30);

  /// The coloured squares behind settings-row icons in the screenshots.
  static const tileBlue = Color(0xFF0A84FF);
  static const tileCyan = Color(0xFF32D6E0);
  static const tileOrange = Color(0xFFFF9500);
  static const tileGreen = Color(0xFF30D158);
  static const tilePurple = Color(0xFF5E5CE6);
  static const tileYellow = Color(0xFFFFD60A);
  static const tileMagenta = Color(0xFFBF5AF2);
}
