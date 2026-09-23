import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// The floating heart on the movie/series detail poster (top-right, facing
/// the back button). Same list as "+ My List" and the heart on Home: a
/// saved title shows a filled red heart, and the heart pops when toggled.
class FavoriteHeartButton extends StatefulWidget {
  const FavoriteHeartButton({
    super.key,
    required this.isFavorite,
    required this.title,
    required this.onToggle,
  });

  final bool isFavorite;
  final String title;
  final VoidCallback onToggle;

  @override
  State<FavoriteHeartButton> createState() => _FavoriteHeartButtonState();
}

class _FavoriteHeartButtonState extends State<FavoriteHeartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _tap() {
    final adding = !widget.isFavorite;
    HapticFeedback.lightImpact();
    widget.onToggle();
    _pop.forward(from: 0);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(adding
            ? 'Added "${widget.title}" to Favorites'
            : 'Removed "${widget.title}" from Favorites'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: Insets.lg,
      top: MediaQuery.paddingOf(context).top + Insets.sm,
      child: Semantics(
        button: true,
        label: widget.isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
        child: Material(
          color: Colors.black.withValues(alpha: 0.45),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: _tap,
            customBorder: const CircleBorder(),
            focusColor: Colors.white24,
            child: SizedBox(
              width: 42,
              height: 42,
              child: AnimatedBuilder(
                animation: _pop,
                builder: (context, child) {
                  // Quick overshoot: 1 -> 1.3 -> 1.
                  final t = _pop.value;
                  final scale = 1 + 0.3 * (t < 0.5 ? t * 2 : (1 - t) * 2);
                  return Transform.scale(scale: scale, child: child);
                },
                child: Icon(
                  widget.isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: widget.isFavorite ? AppColors.accent : Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
