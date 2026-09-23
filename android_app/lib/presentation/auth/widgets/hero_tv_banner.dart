import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';

/// The hero banner on the setup screen: a stylised TV showing a content grid.
///
/// Drawn entirely from widgets rather than shipped as an image — it costs no
/// APK size, scales to any screen, and themes itself from [AppColors]. It is
/// this app's own artwork, not a copy of anyone's screenshot.
///
/// Performance (spec §40): flat gradients and rounded rectangles only. No
/// blur, no shadows on the individual tiles, and the whole thing is const
/// where possible so it never rebuilds.
class HeroTvBanner extends StatelessWidget {
  const HeroTvBanner({super.key});

  /// Tile hues. Deliberately muted so the crimson accent still leads.
  static const _tileColors = <List<Color>>[
    [Color(0xFF3A3F5C), Color(0xFF232637)],
    [Color(0xFF5C3A4A), Color(0xFF37232B)],
    [Color(0xFF2F4A55), Color(0xFF1E2E35)],
    [Color(0xFF4A3F5C), Color(0xFF2B2537)],
    [Color(0xFF5C4A3A), Color(0xFF372D23)],
    [Color(0xFF34513F), Color(0xFF203025)],
  ];

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.lg),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E1B24), Color(0xFF120F16)],
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // A soft accent wash behind the screen, standing in for the
            // glow a real promo render would have.
            Positioned(
              right: -40,
              top: -30,
              child: Container(
                width: 200,
                height: 200,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [Color(0x33F5104A), Color(0x00F5104A)],
                  ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.xl, Insets.lg, Insets.xl, Insets.md),
              child: Column(
                children: [
                  Expanded(
                    child: _ScreenBody(),
                  ),
                  const SizedBox(height: Insets.sm),
                  // Stand.
                  Container(
                    width: 54,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    width: 96,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The TV panel itself: bezel plus a grid of poster placeholders.
class _ScreenBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B0A0E),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: AppColors.divider, width: 1.5),
      ),
      padding: const EdgeInsets.all(Insets.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Derive the grid from the available box so the banner looks right
          // on a phone, a tablet and a TV without magic numbers.
          const columns = 4;
          const rows = 3;
          const gap = 4.0;
          final tileWidth =
              (constraints.maxWidth - gap * (columns - 1)) / columns;
          final tileHeight =
              (constraints.maxHeight - gap * (rows - 1)) / rows;

          return Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var r = 0; r < rows; r++)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var c = 0; c < columns; c++)
                      _Tile(
                        width: tileWidth,
                        height: tileHeight,
                        // The first tile of the middle row is the "featured"
                        // one, tinted with the brand accent.
                        colors: (r == 1 && c == 0)
                            ? const [AppColors.accent, Color(0xFF8E0B2B)]
                            : HeroTvBanner._tileColors[
                                (r * columns + c) % HeroTvBanner._tileColors.length],
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.width,
    required this.height,
    required this.colors,
  });

  final double width;
  final double height;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
    );
  }
}
