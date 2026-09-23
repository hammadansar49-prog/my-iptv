import 'dart:ui' show ImageFilter;
import 'dart:async';
import '../../core/utils/app_orientation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:url_launcher/url_launcher.dart';
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
import 'player_controls.dart';
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
  double? _brightness;
  VideoAspect _aspect = VideoAspect.original;

  /// Bumped on every aspect change so the badge replays its animation.
  int _aspectShown = 0;
  PlaybackRequest? _previous;
  Timer? _hideTimer;
  Timer? _historyTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _player = PlayerController(
      guard: ref.read(connectionGuardProvider),
    )..addListener(_onPlayerChanged);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    unawaited(WakelockPlus.enable());
    unawaited(_readBrightness());

    unawaited(_start());
    _scheduleHide();

    // History is written on a slow ticker rather than on every position
    // event — spec §31 says do not write to storage every second.
    _historyTicker = Timer.periodic(Playback.historyThrottle, (_) {
      _recordProgress();
    });
  }

  /// Screen brightness. Handled defensively: some devices/ROMs refuse the
  /// call, and a slider that cannot move is better than a crash.
  Future<void> _readBrightness() async {
    try {
      final value = await ScreenBrightness().application;
      if (mounted) setState(() => _brightness = value);
    } catch (_) {
      if (mounted) setState(() => _brightness = null);
    }
  }

  Future<void> _setBrightness(double value) async {
    setState(() => _brightness = value);
    try {
      await ScreenBrightness().setApplicationScreenBrightness(value);
    } catch (_) {
      // Ignored: the slider still tracks the gesture, the OS just declined.
    }
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
    unawaited(_resolveNeighbours());
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


  /// Hand the stream to whatever external player the device has (VLC, MX
  /// Player, ...) via a normal VIEW intent. Real behaviour, not a decorative
  /// button — but it genuinely can fail if nothing is installed, and then it
  /// says so instead of silently doing nothing.
  Future<void> _openExternally() async {
    final source = _player.state.request?.resolvedSource;
    if (source == null) return;
    await _player.pause();
    try {
      final uri = Uri.parse(source);
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text('No external player is installed to handle this.'),
          ));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Could not open an external player.'),
        ));
    }
  }

  Future<void> _playRequest(PlaybackRequest request) async {
    setState(() {
      _upNext = null;
      _previous = null;
      _upNextResolved = false;
      _autoplayDismissed = false;
    });
    await _player.open(request);
    unawaited(_resolveNeighbours());
  }

  Future<void> _showSpeedSheet() async {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(Insets.lg),
              child: Text('Playback speed',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            for (final speed in speeds)
              ListTile(
                title: Text('${speed}x'),
                onTap: () {
                  _player.setSpeed(speed);
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTracksSheet() async {
    final audio = _player.audioTracks;
    final subtitles = _player.subtitleTracks;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceHigh,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(Insets.lg),
              child: Text('Audio',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (audio.isEmpty)
              const ListTile(title: Text('No audio tracks reported'))
            else
              for (final track in audio)
                ListTile(
                  title: Text(track.title ?? track.language ?? track.id),
                  onTap: () {
                    _player.setAudioTrack(track);
                    Navigator.of(context).pop();
                  },
                ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(Insets.lg),
              child: Text('Subtitles',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (subtitles.isEmpty)
              const ListTile(title: Text('No subtitle tracks reported'))
            else
              for (final track in subtitles)
                ListTile(
                  title: Text(track.title ?? track.language ?? track.id),
                  onTap: () {
                    _player.setSubtitleTrack(track);
                    Navigator.of(context).pop();
                  },
                ),
          ],
        ),
      ),
    );
  }

  /// Resolve the previous/next episode so the skip buttons are live during
  /// playback, not only once an episode ends.
  Future<void> _resolveNeighbours() async {
    final replay = widget.request.replay;
    if (replay == null ||
        replay.section != ContentSection.series ||
        replay.seriesId == null) {
      return;
    }
    final repo = ref.read(contentRepositoryProvider);
    if (repo == null) return;

    final all = await repo.seriesList();
    Series? match;
    for (final s in all) {
      if (s.seriesId == replay.seriesId) match = s;
    }
    if (match == null || !mounted) return;
    final detail = await repo.seriesDetail(match);
    if (detail == null || !mounted) return;

    final ordered = <Episode>[];
    for (final n in detail.seasonNumbers) {
      ordered.addAll(detail.seasons[n] ?? const []);
    }
    final index = ordered.indexWhere((e) => e.id == replay.episodeId);
    if (index < 0) return;

    PlaybackRequest build(Episode e) => PlaybackRequest(
          url: repo.episodeUrl(e),
          title: detail.series.name,
          subtitle: '${e.tag} - ${e.title}',
          isLive: false,
          historyKey: e.key,
          thumb: e.still ?? detail.series.cover,
          section: ContentSection.series,
          replay: PlaybackRef(
            section: ContentSection.series,
            streamId: e.id,
            seriesId: detail.series.seriesId,
            season: e.season,
            episodeId: e.id,
            ext: e.ext,
          ),
        );

    if (!mounted) return;
    setState(() {
      _previous = index > 0 ? build(ordered[index - 1]) : null;
      _upNext =
          index + 1 < ordered.length ? build(ordered[index + 1]) : null;
      _upNextResolved = true;
    });
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
    try {
      unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    } catch (_) {}
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(AppOrientation.restore(isTv: ref.read(isTvProvider)));
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
                  fit: _aspect.fit,
                  aspectRatio: _aspect.ratio ?? _player.displayAspect,
                ),

              if (_aspectShown > 0)
                IgnorePointer(
                  child: Center(
                    child: _AspectBadge(
                      key: ValueKey(_aspectShown),
                      label: _aspect.label,
                    ),
                  ),
                ),

              if (state.phase == PlaybackPhase.opening ||
                  state.phase == PlaybackPhase.buffering)
                // Dead centre is where the big Play/Pause and ±10 buttons
                // sit; with the controls up the indicator drew underneath
                // them. Drop it below that row instead while they show.
                Align(
                  alignment: _controlsVisible
                      ? const Alignment(0, 0.3)
                      : Alignment.center,
                  child: const Row(
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
                PlayerControls(
                  player: _player,
                  locked: _locked,
                  title: widget.request.title,
                  subtitle: widget.request.subtitle,
                  isSeries:
                      widget.request.section == ContentSection.series,
                  brightness: _brightness,
                  fit: _aspect.fit,
                  onSeekBy: _seekBy,
                  onSeekTo: _player.seekTo,
                  onToggleLock: () => setState(() => _locked = !_locked),
                  onToggleFit: () => setState(() {
                    _aspect = VideoAspect.values[
                        (_aspect.index + 1) % VideoAspect.values.length];
                    _aspectShown++;
                  }),
                  onBack: () => Navigator.of(context).maybePop(),
                  onInteract: _scheduleHide,
                  onBrightness: _setBrightness,
                  onExternalPlayer: _openExternally,
                  onSpeed: _showSpeedSheet,
                  onTracks: _showTracksSheet,
                  onEpisodes:
                      widget.request.section == ContentSection.series
                          ? () => Navigator.of(context).maybePop()
                          : null,
                  onPrevious: _previous == null
                      ? null
                      : () => _playRequest(_previous!),
                  onNext:
                      _upNext == null ? null : () => _playRequest(_upNext!),
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

/// The aspect modes the ratio button cycles through.
enum VideoAspect {
  /// The stream's real display aspect (see PlayerController.displayAspect).
  original('Original', BoxFit.contain, null),
  wide('16:9', BoxFit.fill, 16 / 9),
  classic('4:3', BoxFit.fill, 4 / 3),

  /// Fill the screen, distorting if the shapes differ.
  stretch('Stretch', BoxFit.fill, null),

  /// Fill the screen without distortion, cropping the edges.
  zoom('Zoom', BoxFit.cover, null);

  const VideoAspect(this.label, this.fit, this.ratio);
  final String label;
  final BoxFit fit;
  final double? ratio;
}

/// A frosted pill naming the new aspect mode: pops in, holds, fades away.
class _AspectBadge extends StatefulWidget {
  const _AspectBadge({super.key, required this.label});

  final String label;

  @override
  State<_AspectBadge> createState() => _AspectBadgeState();
}

class _AspectBadgeState extends State<_AspectBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        // 0-15% pop in, hold, last 25% fade out.
        final opacity = t < 0.15
            ? t / 0.15
            : t > 0.75
                ? (1 - t) / 0.25
                : 1.0;
        final scale = t < 0.15
            ? 0.8 + 0.2 * Curves.easeOutBack.transform(t / 0.15)
            : 1.0;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            ),
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
