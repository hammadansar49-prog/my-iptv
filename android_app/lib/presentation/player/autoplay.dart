import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Countdown shown when an episode finishes (spec §32). The user can start
/// the next one now, or cancel — cancelling must actually stop it, not just
/// hide the card.
class NextEpisodeCountdown extends StatefulWidget {
  const NextEpisodeCountdown({
    super.key,
    required this.title,
    required this.onPlay,
    required this.onCancel,
    this.seconds = 8,
  });

  final String title;
  final VoidCallback onPlay;
  final VoidCallback onCancel;
  final int seconds;

  @override
  State<NextEpisodeCountdown> createState() => _NextEpisodeCountdownState();
}

class _NextEpisodeCountdownState extends State<NextEpisodeCountdown>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.seconds),
  );

  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _controller
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_fired) {
          _fired = true;
          widget.onPlay();
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    // Stopping the controller before disposal means a cancel can never race
    // with the completion callback (spec §64).
    _controller.stop();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(Insets.lg),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Up next',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: Insets.xs),
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Insets.md),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _controller.value,
                    minHeight: 3,
                    backgroundColor: AppColors.divider,
                    valueColor:
                        const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
              ),
              const SizedBox(height: Insets.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      _fired = true;
                      _controller.stop();
                      widget.onCancel();
                    },
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: Insets.sm),
                  FilledButton(
                    onPressed: () {
                      if (_fired) return;
                      _fired = true;
                      _controller.stop();
                      widget.onPlay();
                    },
                    child: const Text('Play now'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
