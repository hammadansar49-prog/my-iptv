import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../services/player/playback_request.dart';
import '../../services/player/player_controller.dart';
import '../settings/settings_controller.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../providers.dart';
import 'autoplay.dart';
import 'seek_feedback.dart';

/// Fullscreen VOD player (movies and episodes).
///
/// Live TV does NOT come here — it plays inline in LiveTvScreen, which is a
/// locked decision from CLAUDE.md.
///
/// Lifecycle (spec §25): the controller, the seek-feedback controller, the
/// controls-hide timer, the progress ticker and the wakelock are all created
/// here and all torn down in dispose. Nothing outlives the route.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.request});

  final PlaybackRequest request;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late final PlayerController _player;
  final _seekFeedback = SeekFeedbackController();

  /// The episode queued to follow this one, resolved once playback nears
  /// the end rather than up front (spec §44: no speculative fetching).
  PlaybackRequest? _upNext;
  bool _upNextResolved = false;
  bool _autoplayDismissed = false;

  bool _controlsVisible = true;
  bool _locked = false;
  Timer? _hideTimer;
  Timer? _historyTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _player = PlayerController(
      guard: ref.read(connectionGuardProvider),
      http: ref.read(httpClientProvider),
    )..addListener(_onPlayerChanged);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    unawaited(WakelockPlus.enable());

    unawaited(_start());
    _scheduleHide();

    // History is written on a slow ticker rather than on every position
    // event — spec §31 says do not write to storage every second.
    _historyTicker = Timer.periodic(Playback.historyThrottle, (_) {
      _recordProgress();
    });
  }

  Future<void> _start() async {
    // A completed download plays from disk — the remote stream is never
    // requested again (spec §29).
    final local =
        ref.read(downloadManagerProvider).localFileFor(widget.request.url);

    // Resume from the saved position, applied as the stream's start point
    // rather than as a seek after playback begins (AUDIT.md §3).
    final saved =
        ref.read(libraryRepositoryProvider).historyFor(widget.request.historyKey);
    final resumeAt = saved != null && saved.isContinueWatching
        ? saved.resumeAt
        : widget.request.startAt;

    await _player.open(PlaybackRequest(
      url: widget.request.url,
      title: widget.request.title,
      subtitle: widget.request.subtitle,
      thumb: widget.request.thumb,
      isLive: widget.request.isLive,
      historyKey: widget.request.historyKey,
      startAt: resumeAt,
      replay: widget.request.replay,
      section: widget.request.section,
      localFile: local,
    ));
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    if (_player.state.phase == PlaybackPhase.ended) {
      unawaited(_resolveUpNext());
    }
    setState(() {});
  }

  /// Find the next episode in playback order. Only meaningful for series,
  /// and only asked for once.
  Future<void> _resolveUpNext() async {
    if (_upNextResolved) return;
    _upNextResolved = true;

    final replay = widget.request.replay;
    if (replay == null ||
        replay.section != ContentSection.series ||
        replay.seriesId == null) {
      return;
    }
    if (!ref.read(settingsProvider).autoPlayNextEpisode) return;

    final repo = ref.read(contentRepositoryProvider);
    if (repo == null) return;

    // The series detail is already cached from the details screen, so this
    // normally costs nothing.
    final seriesList = await repo.seriesList();
    Series? match;
    for (final s in seriesList) {
      if (s.seriesId == replay.seriesId) {
        match = s;
        break;
      }
    }
    if (match == null || !mounted) return;

    final detail = await repo.seriesDetail(match);
    if (detail == null || !mounted) return;

    Episode? current;
    for (final list in detail.seasons.values) {
      for (final e in list) {
        if (e.id == replay.episodeId) current = e;
      }
    }
    if (current == null) return;

    final next = detail.nextAfter(current);
    if (next == null || !mounted) return;

    setState(() {
      _upNext = PlaybackRequest(
        url: repo.episodeUrl(next),
        title: detail.series.name,
        subtitle: '${next.tag} · ${next.title}',
        isLive: false,
        historyKey: next.key,
        thumb: next.still ?? detail.series.cover,
        section: ContentSection.series,
        replay: PlaybackRef(
          section: ContentSection.series,
          streamId: next.id,
          seriesId: detail.series.seriesId,
          season: next.season,
          episodeId: next.id,
          ext: next.ext,
        ),
      );
    });
  }

  Future<void> _playUpNext() async {
    final next = _upNext;
    if (next == null) return;
    // Reset the per-item state so the new episode behaves like a fresh open.
    setState(() {
      _upNext = null;
      _upNextResolved = false;
      _autoplayDismissed = false;
    });
    await _player.open(next);
  }

  void _recordProgress() {
    final state = _player.state;
    if (state.request == null || state.isLive) return;
    if (state.duration <= Duration.zero) return;
    unawaited(ref.read(libraryRepositoryProvider).recordProgress(
          widget.request.toHistoryEntry(),
          position: state.position,
          duration: state.duration,
        ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding releases the provider connection; a one-connection
    // account cannot afford to hold it while the app is not visible.
    if (state == AppLifecycleState.paused) {
      _recordProgress();
      unawaited(_player.pause());
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(Playback.controlsAutoHide, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  /// Spec §20/§21: a ±10 press seeks AND shows the overlay, and repeated
  /// presses accumulate into one overlay and one in-flight seek.
  Future<void> _seekBy(Duration delta) async {
    if (_player.state.isLive) return;
    _seekFeedback.register(delta);
    if (!_controlsVisible) {
      // Keep the overlay readable without forcing the full control bar up.
      _scheduleHide();
    }
    await _player.seekBy(delta);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _historyTicker?.cancel();

    // Final flush, bypassing the throttle, so the exact stop position sticks.
    _recordProgress();
    unawaited(ref.read(libraryRepositoryProvider).flushProgress());

    _player.removeListener(_onPlayerChanged);
    unawaited(_player.dispose());
    _seekFeedback.dispose();

    unawaited(WakelockPlus.disable());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _player.state;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        // Android TV remote (spec §38): D-pad left/right seek, OK toggles
        // play/pause, back leaves.
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          switch (event.logicalKey) {
            case LogicalKeyboardKey.arrowRight:
            case LogicalKeyboardKey.mediaFastForward:
              unawaited(_seekBy(Playback.seekStep));
              return KeyEventResult.handled;
            case LogicalKeyboardKey.arrowLeft:
            case LogicalKeyboardKey.mediaRewind:
              unawaited(_seekBy(-Playback.seekStep));
              return KeyEventResult.handled;
            case LogicalKeyboardKey.select:
            case LogicalKeyboardKey.enter:
            case LogicalKeyboardKey.space:
            case LogicalKeyboardKey.mediaPlayPause:
              unawaited(_player.playPause());
              _toggleControls();
              return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: _toggleControls,
          onDoubleTapDown: _locked
              ? null
              : (details) {
                  // Netflix-style double tap: left half rewinds, right half
                  // fast-forwards.
                  final width = MediaQuery.sizeOf(context).width;
                  final forward = details.globalPosition.dx > width / 2;
                  unawaited(
                      _seekBy(forward ? Playback.seekStep : -Playback.seekStep));
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_player.videoController != null)
                Video(
                  controller: _player.videoController!,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                ),

              if (state.phase == PlaybackPhase.opening ||
                  state.phase == PlaybackPhase.buffering)
                const Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: Insets.md),
                      Text('Buffering...',
                          style:
                              TextStyle(color: Colors.white, fontSize: 16)),
                    ],
                  ),
                ),

              // The mandatory ±10 overlay.
              SeekFeedbackOverlay(controller: _seekFeedback),

              if (state.phase == PlaybackPhase.failed)
                _ErrorOverlay(
                  message: state.error?.message ?? 'Unable to play this stream.',
                  onRetry: _player.retry,
                  onBack: () => Navigator.of(context).maybePop(),
                ),

              if (_upNext != null &&
                  !_autoplayDismissed &&
                  state.phase == PlaybackPhase.ended)
                NextEpisodeCountdown(
                  title: _upNext!.subtitle.isEmpty
                      ? _upNext!.title
                      : _upNext!.subtitle,
                  onPlay: _playUpNext,
                  onCancel: () => setState(() => _autoplayDismissed = true),
                ),

              if (_controlsVisible && state.phase != PlaybackPhase.failed)
                _Controls(
                  player: _player,
                  locked: _locked,
                  title: widget.request.title,
                  subtitle: widget.request.subtitle,
                  onSeekBy: _seekBy,
                  onToggleLock: () => setState(() => _locked = !_locked),
                  onBack: () => Navigator.of(context).maybePop(),
                  onInteract: _scheduleHide,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onBack,
  });

  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.8),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Insets.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.danger, size: 40),
          const SizedBox(height: Insets.lg),
          // Plain text only — never a stack trace or raw HTML (spec §24).
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: Insets.xl),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: () => onRetry(),
                child: const Text('Retry'),
              ),
              const SizedBox(width: Insets.md),
              TextButton(onPressed: onBack, child: const Text('Back')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.locked,
    required this.title,
    required this.subtitle,
    required this.onSeekBy,
    required this.onToggleLock,
    required this.onBack,
    required this.onInteract,
  });

  final PlayerController player;
  final bool locked;
  final String title;
  final String subtitle;
  final Future<void> Function(Duration) onSeekBy;
  final VoidCallback onToggleLock;
  final VoidCallback onBack;
  final VoidCallback onInteract;

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final state = player.state;

    if (locked) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: _RoundButton(
            icon: Icons.lock_rounded,
            onTap: onToggleLock,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.65),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: Column(
        children: [
          // Top bar
          Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Row(
              children: [
                _RoundButton(icon: Icons.arrow_back_rounded, onTap: onBack),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                _RoundButton(icon: Icons.lock_open_rounded, onTap: onToggleLock),
              ],
            ),
          ),

          const Spacer(),

          // Transport
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RoundButton(
                icon: Icons.replay_10_rounded,
                size: 52,
                onTap: () {
                  onInteract();
                  onSeekBy(-Playback.seekStep);
                },
              ),
              const SizedBox(width: Insets.xl),
              _RoundButton(
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
              const SizedBox(width: Insets.xl),
              _RoundButton(
                icon: Icons.forward_10_rounded,
                size: 52,
                onTap: () {
                  onInteract();
                  onSeekBy(Playback.seekStep);
                },
              ),
            ],
          ),

          const Spacer(),

          // Progress. Live streams never get a VOD scrubber (spec §23).
          if (state.showsProgressBar)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.lg, 0, Insets.lg, Insets.md),
              child: Row(
                children: [
                  Text(_fmt(state.position),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: AppColors.accent,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: AppColors.accent,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                      ),
                      child: Slider(
                        value: state.position.inMilliseconds
                            .clamp(0, state.duration.inMilliseconds)
                            .toDouble(),
                        max: state.duration.inMilliseconds.toDouble(),
                        onChanged: (v) {
                          onInteract();
                          player.seekTo(
                              Duration(milliseconds: v.round()));
                        },
                      ),
                    ),
                  ),
                  Text(_fmt(state.duration),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(bottom: Insets.xl),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.circle, color: AppColors.danger, size: 9),
                  SizedBox(width: Insets.sm),
                  Text('LIVE',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.accent = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent ? AppColors.accent : Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        focusColor: Colors.white24,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.5),
        ),
      ),
    );
  }
}
