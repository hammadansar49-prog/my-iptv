import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// The mandatory ±10 second seek animation (spec §20, §21, §38).
///
/// Requirements it has to meet:
///  * immediate, smooth, clearly visible, professional
///  * lightweight — no CPU spike, no leak
///  * rapid repeats REUSE this one overlay and accumulate (+10, +20, +30…)
///    rather than stacking widgets or spawning controllers
///
/// One AnimationController for the whole widget lifetime; a repeat press
/// restarts it via `forward(from: 0)`. Nothing is allocated per press.
class SeekFeedbackController extends ChangeNotifier {
  Duration _accumulated = Duration.zero;
  bool _forward = true;
  int _revision = 0;
  Timer? _resetTimer;

  Duration get accumulated => _accumulated;
  bool get isForward => _forward;

  /// Bumped on every press so the view knows to restart its animation even
  /// when the direction and total are unchanged.
  int get revision => _revision;

  /// How long the overlay stays up after the last press.
  static const window = Duration(milliseconds: 900);

  void register(Duration delta) {
    final sameDirection = (delta.isNegative == _accumulated.isNegative);
    if (_accumulated == Duration.zero || !sameDirection) {
      _accumulated = delta;
    } else {
      _accumulated += delta;
    }
    _forward = !delta.isNegative;
    _revision++;
    notifyListeners();

    _resetTimer?.cancel();
    _resetTimer = Timer(window, () {
      _accumulated = Duration.zero;
      _revision++;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    _resetTimer = null;
    super.dispose();
  }
}

class SeekFeedbackOverlay extends StatefulWidget {
  const SeekFeedbackOverlay({super.key, required this.controller});

  final SeekFeedbackController controller;

  @override
  State<SeekFeedbackOverlay> createState() => _SeekFeedbackOverlayState();
}

class _SeekFeedbackOverlayState extends State<SeekFeedbackOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  late final Animation<double> _fade = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 18),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 52),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
  ]).animate(_anim);

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.82, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 30,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 70),
  ]).animate(_anim);

  int _seenRevision = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  void _onChange() {
    final c = widget.controller;
    if (c.revision == _seenRevision) return;
    _seenRevision = c.revision;
    if (c.accumulated == Duration.zero) {
      // The window closed; let the current run finish fading out.
      return;
    }
    // Rapid repeats restart the SAME animation — spec §21.
    _anim.forward(from: 0);
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final seconds = c.accumulated.inSeconds.abs();

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          if (_fade.value <= 0.01 || seconds == 0) {
            return const SizedBox.shrink();
          }
          return Opacity(
            opacity: _fade.value,
            child: Align(
              alignment:
                  c.isForward ? Alignment.centerRight : Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: 0.34,
                child: Transform.scale(
                  scale: _scale.value,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(120),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          c.isForward
                              ? Icons.fast_forward_rounded
                              : Icons.fast_rewind_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${c.isForward ? '+' : '-'}$seconds',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Text(
                          'seconds',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
