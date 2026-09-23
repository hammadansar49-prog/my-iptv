import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../services/player/player_controller.dart';
import 'seek_bar.dart';

/// The fullscreen control overlay.
///
/// Shared by movies, series and live, with the live-inappropriate parts
/// removed per spec §23: no VOD scrubber, no episode navigation, and a LIVE
/// badge instead of a duration.
class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.locked,
    required this.title,
    required this.subtitle,
    required this.isSeries,
    required this.brightness,
    required this.fit,
    required this.onSeekBy,
    required this.onSeekTo,
    required this.onToggleLock,
    required this.onToggleFit,
    required this.onBack,
    required this.onInteract,
    required this.onBrightness,
    required this.onExternalPlayer,
    required this.onSpeed,
    required this.onTracks,
    this.onEpisodes,
    this.onPrevious,
    this.onNext,
  });

  final PlayerController player;
  final bool locked;
  final String title;
  final String subtitle;
  final bool isSeries;
  final double? brightness;
  final BoxFit fit;
  final Future<void> Function(Duration) onSeekBy;
  final ValueChanged<Duration> onSeekTo;
  final VoidCallback onToggleLock;
  final VoidCallback onToggleFit;
  final VoidCallback onBack;
  final VoidCallback onInteract;
  final ValueChanged<double> onBrightness;
  final VoidCallback onExternalPlayer;
  final VoidCallback onSpeed;
  final VoidCallback onTracks;
  final VoidCallback? onEpisodes;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  static String formatTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final state = player.state;
    final isLive = state.isLive;

    // Locked hides every other control — spec §22 wants a real lock, not a
    // decorative one.
    if (locked) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: RoundPlayerButton(
              icon: Icons.lock_rounded, onTap: onToggleLock),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.70),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.80),
          ],
          stops: const [0, 0.42, 1],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            // ---- Top bar -------------------------------------------------
            Positioned(
              left: Insets.md,
              right: Insets.md,
              top: Insets.sm,
              child: Row(
                children: [
                  RoundPlayerButton(
                      icon: Icons.arrow_back_rounded, onTap: onBack),
                  const Spacer(),
                  PlayerPill(
                    label: 'VLC',
                    icon: Icons.swap_horiz_rounded,
                    onTap: () {
                      onInteract();
                      onExternalPlayer();
                    },
                  ),
                  const SizedBox(width: Insets.sm),
                  RoundPlayerButton(
                    icon: Icons.aspect_ratio_rounded,
                    onTap: () {
                      onInteract();
                      onToggleFit();
                    },
                  ),
                  const SizedBox(width: Insets.sm),
                  RoundPlayerButton(
                      icon: Icons.lock_open_rounded, onTap: onToggleLock),
                ],
              ),
            ),

            // ---- Title ---------------------------------------------------
            Positioned(
              left: 72,
              right: 72,
              top: 54,
              child: Text(
                subtitle.isEmpty ? title : '$title - $subtitle',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // ---- Brightness ----------------------------------------------
            if (brightness != null)
              Positioned(
                left: Insets.md,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _BrightnessSlider(
                    value: brightness!,
                    onChanged: (v) {
                      onInteract();
                      onBrightness(v);
                    },
                  ),
                ),
              ),

            // ---- Transport -----------------------------------------------
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isLive) ...[
                    RoundPlayerButton(
                      icon: Icons.replay_10_rounded,
                      size: 50,
                      onTap: () {
                        onInteract();
                        onSeekBy(-Playback.seekStep);
                      },
                    ),
                    const SizedBox(width: Insets.lg),
                  ],
                  if (isSeries) ...[
                    RoundPlayerButton(
                      icon: Icons.skip_previous_rounded,
                      size: 46,
                      enabled: onPrevious != null,
                      onTap: () {
                        onInteract();
                        onPrevious?.call();
                      },
                    ),
                    const SizedBox(width: Insets.lg),
                  ],
                  RoundPlayerButton(
                    icon: state.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 68,
                    accent: true,
                    onTap: () {
                      onInteract();
                      player.playPause();
                    },
                  ),
                  if (isSeries) ...[
                    const SizedBox(width: Insets.lg),
                    RoundPlayerButton(
                      icon: Icons.skip_next_rounded,
                      size: 46,
                      enabled: onNext != null,
                      onTap: () {
                        onInteract();
                        onNext?.call();
                      },
                    ),
                  ],
                  if (!isLive) ...[
                    const SizedBox(width: Insets.lg),
                    RoundPlayerButton(
                      icon: Icons.forward_10_rounded,
                      size: 50,
                      onTap: () {
                        onInteract();
                        onSeekBy(Playback.seekStep);
                      },
                    ),
                  ],
                ],
              ),
            ),

            // ---- Bottom --------------------------------------------------
            Positioned(
              left: Insets.lg,
              right: Insets.lg,
              bottom: Insets.sm,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isLive)
                    const Padding(
                      padding: EdgeInsets.only(bottom: Insets.md),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _LiveDot(),
                          SizedBox(width: Insets.sm),
                          Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: BufferedSeekBar(
                            position: state.position,
                            buffered: state.buffered,
                            duration: state.duration,
                            onSeek: (target) {
                              onInteract();
                              onSeekTo(target);
                            },
                          ),
                        ),
                        const SizedBox(width: Insets.md),
                        Text(
                          formatTime(state.position),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                      ],
                    ),
                  const SizedBox(height: Insets.sm),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (isSeries && onEpisodes != null) ...[
                          PlayerPill(
                            label: 'Episodes',
                            icon: Icons.playlist_play_rounded,
                            onTap: () {
                              onInteract();
                              onEpisodes!();
                            },
                          ),
                          const SizedBox(width: Insets.sm),
                        ],
                        PlayerPill(
                          label: 'Speed',
                          icon: Icons.speed_rounded,
                          onTap: () {
                            onInteract();
                            onSpeed();
                          },
                        ),
                        const SizedBox(width: Insets.sm),
                        PlayerPill(
                          label: 'Tracks',
                          icon: Icons.equalizer_rounded,
                          onTap: () {
                            onInteract();
                            onTracks();
                          },
                        ),
                      ],
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

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) => Container(
        width: 9,
        height: 9,
        decoration: const BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
        ),
      );
}

/// Vertical brightness slider with a sun icon, per the reference.
class _BrightnessSlider extends StatelessWidget {
  const _BrightnessSlider({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: Insets.md),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 130,
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value.clamp(0.0, 1.0),
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          const Icon(Icons.brightness_5_rounded, color: Colors.white, size: 18),
        ],
      ),
    );
  }
}

class PlayerPill extends StatelessWidget {
  const PlayerPill({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        focusColor: Colors.white24,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.md, vertical: Insets.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 17),
              const SizedBox(width: Insets.sm),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class RoundPlayerButton extends StatelessWidget {
  const RoundPlayerButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.accent = false,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final bool accent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: accent ? AppColors.accent : Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          focusColor: Colors.white24,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, color: Colors.white, size: size * 0.5),
          ),
        ),
      ),
    );
  }
}
