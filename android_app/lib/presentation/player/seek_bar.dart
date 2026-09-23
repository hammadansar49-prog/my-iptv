import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Three-layer scrubber: played (accent) → buffered-ahead (translucent
/// white) → not buffered (dark track).
///
/// On the PC app the equivalent bar needs a merge step, because
/// `video.buffered` under MediaSource reports many tiny near-touching ranges
/// and drawing them raw produces a strip of slivers (CLAUDE.md, locked).
/// **media_kit does not have that problem**: libmpv exposes a single
/// coalesced buffered position (`player.state.buffer` is one `Duration`, and
/// there is no range list in its API — verified in media_kit 1.2.6's
/// `PlayerState`). There is nothing to merge, so the merge step has no
/// counterpart here rather than being "simplified away". If a future
/// media_kit version starts exposing discrete ranges, reinstate the merge
/// before drawing them.
class BufferedSeekBar extends StatelessWidget {
  const BufferedSeekBar({
    super.key,
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onSeek,
    this.enabled = true,
  });

  final Duration position;
  final Duration buffered;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    if (total <= 0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.divider,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }

    final playedFraction = (position.inMilliseconds / total).clamp(0.0, 1.0);
    // The buffer can legitimately sit behind the playhead right after a seek;
    // never draw a "buffered" strip shorter than what has been played.
    final bufferedFraction =
        (buffered.inMilliseconds / total).clamp(playedFraction, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        void seekTo(double dx) {
          if (!enabled) return;
          final fraction = (dx / width).clamp(0.0, 1.0);
          onSeek(Duration(milliseconds: (total * fraction).round()));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekTo(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekTo(d.localPosition.dx),
          child: SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Layer 3 — the whole track, not buffered.
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Layer 2 — buffered ahead of the playhead.
                FractionallySizedBox(
                  widthFactor: bufferedFraction,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.32),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Layer 1 — played.
                FractionallySizedBox(
                  widthFactor: playedFraction,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Thumb.
                Positioned(
                  left: (playedFraction * width - 7).clamp(0.0, width - 14),
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
