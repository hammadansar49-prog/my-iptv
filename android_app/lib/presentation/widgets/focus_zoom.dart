import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// TV/mouse feedback for a poster or tile: while it (or anything inside it,
/// such as its InkWell) has remote focus, or the mouse hovers it, it grows
/// a little with a smooth animation and gets a white border, so it is always
/// clear which item is selected. Touch never focuses or hovers, so phones
/// look exactly as before.
class FocusZoom extends StatefulWidget {
  const FocusZoom({
    super.key,
    required this.child,
    this.radius = 10,
    this.scale = 1.08,
  });

  final Widget child;
  final double radius;
  final double scale;

  @override
  State<FocusZoom> createState() => _FocusZoomState();
}

class _FocusZoomState extends State<FocusZoom> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final on = _focused || _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) {
          if (f != _focused) setState(() => _focused = f);
          if (f) {
            // Keep the focused item on screen while moving with the remote.
            Scrollable.ensureVisible(
              context,
              alignment: 0.5,
              alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              duration: const Duration(milliseconds: 160),
            );
          }
        },
        child: AnimatedScale(
          scale: on ? widget.scale : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              border: Border.all(
                color: on ? Colors.white : Colors.transparent,
                width: 3,
              ),
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.35),
                        blurRadius: 18,
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
