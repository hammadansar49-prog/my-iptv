import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// TV/mouse feedback for a poster or tile: the selected item grows a little
/// with a smooth animation and gets a white border, so it is always clear
/// which one is selected. Touch never focuses or hovers, so phones look
/// exactly as before.
///
/// Only ONE item is ever highlighted: whichever was selected last, by the
/// remote (focus) or the mouse (hover). Before, a parked mouse cursor and
/// the remote's focus lit up two posters at once.
class FocusZoom extends StatefulWidget {
  const FocusZoom({
    super.key,
    required this.child,
    this.radius = 10,
    this.scale = 1.06,
  });

  final Widget child;
  final double radius;
  final double scale;

  /// The single highlighted item, app-wide.
  static final ValueNotifier<Object?> _active = ValueNotifier(null);

  @override
  State<FocusZoom> createState() => _FocusZoomState();
}

class _FocusZoomState extends State<FocusZoom> {
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    FocusZoom._active.addListener(_onActive);
  }

  @override
  void dispose() {
    FocusZoom._active.removeListener(_onActive);
    if (FocusZoom._active.value == this) FocusZoom._active.value = null;
    super.dispose();
  }

  void _onActive() {
    if (mounted) setState(() {});
  }

  void _claim() => FocusZoom._active.value = this;

  void _release() {
    if (!_focused && !_hovered && FocusZoom._active.value == this) {
      FocusZoom._active.value = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = (_focused || _hovered) && FocusZoom._active.value == this;
    return MouseRegion(
      // A parked cursor must not steal the highlight when the remote
      // scrolls a new poster underneath it: only real mouse movement
      // (onHover) selects; onEnter alone (fired by scrolling) does not.
      onEnter: (_) => _hovered = true,
      onHover: (_) {
        _hovered = true;
        if (FocusZoom._active.value != this) _claim();
      },
      onExit: (_) {
        _hovered = false;
        _release();
        setState(() {});
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) {
          _focused = f;
          if (f) {
            _claim();
            // The TV "tick" as the remote moves between posters (only the
            // remote/keyboard focuses these, so phones stay silent). Plays
            // through Android's own click sound.
            SystemSound.play(SystemSoundType.click);
            // Keep the selected item on screen while moving with the remote.
            Scrollable.ensureVisible(
              context,
              alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              duration: const Duration(milliseconds: 120),
            );
          } else {
            _release();
            setState(() {});
          }
        },
        // Its own layer: the zoom animates a transform only, so the poster
        // is not repainted every frame (that is what made it stutter on TV
        // boxes, together with a blurred glow, now removed).
        child: RepaintBoundary(
          child: AnimatedScale(
            scale: on ? widget.scale : 1,
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                border: on
                    ? Border.all(color: Colors.white, width: 3)
                    : null,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
