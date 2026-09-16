import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

/// The one player used everywhere: live channels, movies, episodes and
/// downloaded files. Built on media_kit (libmpv), which — unlike Android's
/// own ExoPlayer — decodes almost anything a provider sends (MKV, HEVC,
/// AC3/DTS audio) without any server-side transcoding, and exposes real
/// audio/subtitle track lists the way the desktop app does.
class PlayerScreen extends StatefulWidget {
  final AppState state;
  final PlayRequest request;
  final String? favSection;
  final PlayableItem? favItem;

  /// True while shown as the small floating PiP box instead of full-screen.
  /// The widget itself (and its State — the live Player/connection) is kept
  /// alive across this toggle by the caller reusing the same GlobalKey
  /// (see AppState.playerLaunch / main.dart's overlay) — nothing here ever
  /// gets torn down and reconnected just because the box got bigger or
  /// smaller.
  final bool mini;

  const PlayerScreen({
    super.key,
    required this.state,
    required this.request,
    this.favSection,
    this.favItem,
    this.mini = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player player;
  late final VideoController videoController;
  late PlayRequest request;

  bool loading = true;
  String? error;
  bool controlsVisible = true;
  Timer? hideTimer;
  Timer? saveTimer;
  bool resumed = false;
  bool seeking = false;
  double dragValue = 0;
  double speed = 1.0;
  static const speeds = [0.5, 1.0, 1.25, 1.5, 2.0];
  BoxFit videoFit = BoxFit.contain;
  double? _doubleTapX;
  int? _seekFlash;
  Timer? _seekFlashTimer;
  bool? _dragOnLeft;
  double _dragStartBrightness = 0.5;
  double _dragStartVolume = 100;
  double? _hudBrightness;
  double? _hudVolume;
  Timer? _hudTimer;
  static const _fitLabels = {
    BoxFit.contain: 'Fit',
    BoxFit.cover: 'Zoom / Fill',
    BoxFit.fill: 'Stretch (16:9)',
  };

  StreamSubscription? _errSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _bufferingSub;
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _stallTimer;
  Timer? _freezeTimer;
  Duration _lastFreezeCheckPos = Duration.zero;
  int _freezeStrikes = 0;
  Timer? _audioWatchdog;
  bool _audioWarned = false;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  Duration buffered = Duration.zero;
  bool playing = false;
  bool buffering = true;
  // Separate from `buffering` above (which the freeze watchdog still reads
  // raw and unfiltered) — this is only for the spinner overlay. mpv flips
  // `buffering` true/false for a frame or two on a seek that lands inside
  // its own already-downloaded cache (64MB, see PlayerConfiguration below),
  // which used to flash the loading spinner on every quick forward-skip even
  // though nothing was actually re-fetched from the network. A real stall
  // lasts far longer than this debounce.
  bool _showBufferSpinner = false;
  Timer? _bufferSpinnerTimer;
  Tracks tracks = const Tracks();
  Track currentTrack = const Track();

  @override
  void initState() {
    super.initState();
    request = widget.request;
    _applyChrome();
    WakelockPlus.enable();
    player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024));
    // Hardware decoding produced a black frame with audio still playing on
    // the device this was tested on — a known media_kit/Android issue where
    // the hardware-decoded texture doesn't hand off to the GPU surface
    // correctly on some devices. Software decoding costs more CPU but always
    // renders; safer to ship that than a picture that may not show up.
    videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(hwdec: 'no'),
    );
    _wireStreams();
    if (!request.isLive) widget.state.downloads.playbackStarted();
    widget.state.downloads.addListener(_onDownloadsChanged);
    _beginPlayback();
    _armHideTimer();
  }

  bool _slotHeld = false;

  // Waits for the one-connection-at-a-time gate (see
  // AppState.acquireProviderSlot) before this screen's very first
  // Player.open() — retries/auto-next-episode call `_startPlayback()`
  // directly afterwards and reuse this same held slot. A 5s wait covers "the
  // other player is just finishing closing"; past that we tell the user
  // instead of leaving them on a spinner that never resolves.
  Future<void> _beginPlayback() async {
    final ok = await _acquireProviderSlotOrTimeout();
    if (!mounted) {
      if (ok) widget.state.releaseProviderSlot();
      return;
    }
    if (!ok) {
      setState(() {
        loading = false;
        error = 'This account allows only one stream at a time. Close the other playing video, then try again.';
      });
      return;
    }
    _slotHeld = true;
    await _startPlayback();
  }

  Future<bool> _acquireProviderSlotOrTimeout() async {
    var timedOut = false;
    final acquireFuture = widget.state.acquireProviderSlot().then((_) {
      if (timedOut) {
        widget.state.releaseProviderSlot(); // gave up already — hand it straight back
        return false;
      }
      return true;
    });
    return await Future.any([
      acquireFuture,
      Future.delayed(const Duration(seconds: 5), () { timedOut = true; return false; }),
    ]);
  }

  void _retry() {
    _retries = 0;
    if (_slotHeld) {
      _startPlayback();
    } else {
      _beginPlayback();
    }
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only the mini<->full toggle should touch system chrome/orientation —
    // everything else about playback (Player, connection, watchdogs) is
    // untouched by this, which is the whole point: shrinking/expanding never
    // reconnects.
    if (oldWidget.mini != widget.mini) _applyChrome();
  }

  void _applyChrome() {
    if (widget.mini) {
      // Mini/PiP box: leave the rest of the app free to rotate/scroll behind it.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
  }

  void _onDownloadsChanged() { if (mounted) setState(() {}); }

  void _wireStreams() {
    player.stream.position.listen((p) => mounted ? setState(() => position = p) : null);
    player.stream.duration.listen((d) => mounted ? setState(() => duration = d) : null);
    player.stream.buffer.listen((b) => mounted ? setState(() => buffered = b) : null);
    player.stream.playing.listen((p) => mounted ? setState(() => playing = p) : null);
    _bufferingSub = player.stream.buffering.listen((b) {
      if (!mounted) return;
      setState(() => buffering = b);
      _bufferSpinnerTimer?.cancel();
      if (b) {
        _bufferSpinnerTimer = Timer(const Duration(milliseconds: 350), () {
          if (mounted && buffering) setState(() => _showBufferSpinner = true);
        });
      } else {
        setState(() => _showBufferSpinner = false);
      }
    });
    player.stream.tracks.listen((t) => mounted ? setState(() => tracks = t) : null);
    player.stream.track.listen((t) => mounted ? setState(() => currentTrack = t) : null);
    _completedSub = player.stream.completed.listen((done) {
      if (!done || !mounted) return;
      _onEnded();
    });
    _errSub = player.stream.error.listen((msg) {
      if (!mounted) return;
      _handleFailure(msg);
    });
  }

  // A live channel that briefly drops (provider hiccup, network blip) is
  // worth retrying automatically — libmpv itself doesn't retry a failed
  // open() the way it retries a dropped connection mid-stream. A handful of
  // quick attempts recovers most of those without the user ever seeing an
  // error; a channel that's genuinely off the air still ends up showing one,
  // just a few seconds later instead of on the very first try.
  void _handleFailure(String reason) {
    _stallTimer?.cancel();
    _freezeTimer?.cancel();
    _audioWatchdog?.cancel();
    if (request.isLive && _retries < 3) {
      _retries++;
      setState(() {
        loading = true;
        error = null;
      });
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(milliseconds: 600 * _retries), _startPlayback);
      return;
    }
    setState(() {
      loading = false;
      error = request.isLive
          ? 'This channel is unavailable right now — try another.'
          : 'This stream could not be played.\n$reason';
    });
  }

  Future<void> _startPlayback() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await player.open(Media(request.url, httpHeaders: const {'User-Agent': 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100'}));
      await player.setRate(speed);
      if (!request.isLive && request.resumeAt > 5 && !resumed) {
        resumed = true;
        // Wait for a real duration before deciding the saved position is
        // still inside the film — otherwise a resume right at the very end
        // (already finished) would just replay from there again.
        final dur = await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(
              const Duration(seconds: 8),
              onTimeout: () => Duration.zero,
            );
        if (dur == Duration.zero || request.resumeAt < dur.inSeconds * 0.97) {
          await player.seek(Duration(seconds: request.resumeAt.toInt()));
        }
      }
      if (!mounted) return;
      _retries = 0;
      setState(() => loading = false);
      _startHistoryTimer();
      _armAudioWatchdog();
      // A live channel whose open() succeeds but never actually delivers a
      // frame (some providers accept the connection then go silent) is
      // covered the same way — one more retry rather than sitting on a
      // spinner forever.
      if (request.isLive) {
        _stallTimer?.cancel();
        _stallTimer = Timer(const Duration(seconds: 12), () {
          if (mounted && position == Duration.zero && !playing) _handleFailure('No response from the channel.');
        });
        _armFreezeWatchdog();
      }
    } catch (e) {
      if (!mounted) return;
      _handleFailure('It may be offline or blocked by the provider.');
    }
  }

  // Some providers keep the connection open but the decoded picture just
  // stops advancing — no error event fires because nothing actually failed,
  // the stream simply stalled. Checked only for live (VOD pausing on a
  // scrub/buffer is normal and would false-trigger this). First strike tries
  // a cheap in-place nudge (tiny seek); a second consecutive stall forces a
  // full reconnect the same way a real error would.
  void _armFreezeWatchdog() {
    _freezeTimer?.cancel();
    _lastFreezeCheckPos = position;
    _freezeTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !request.isLive) return;
      if (!playing || buffering) {
        _lastFreezeCheckPos = position;
        return;
      }
      if (position == _lastFreezeCheckPos) {
        _freezeStrikes++;
        if (_freezeStrikes >= 2) {
          _freezeStrikes = 0;
          _handleFailure('The stream stalled.');
        } else {
          final nudge = position + const Duration(milliseconds: 500);
          player.seek(nudge);
        }
      } else {
        _freezeStrikes = 0;
      }
      _lastFreezeCheckPos = position;
    });
  }

  // Best-effort equivalent of the PC app's audio watchdog. On PC (Chromium
  // MediaSource) some channels' AC-3/E-AC-3 audio passes the codec check but
  // never actually decodes — picture plays, channel is silent, no error at
  // all — and the fix there is to ask the server to re-encode. mpv (which
  // this player is built on) decodes AC-3/E-AC-3 natively, so that specific
  // failure mode mostly doesn't happen here; there's no server-side
  // "audiofix" to fall back to on a raw provider URL either. This only
  // covers the milder, real case: a track is selected but mpv's audio
  // pipeline never produces a timestamp while the picture is clearly
  // running — tell the user via a toast instead of leaving them guessing
  // why a channel that "plays" is silent. Never touches video/track state.
  void _armAudioWatchdog() {
    _audioWatchdog?.cancel();
    _audioWarned = false;
    if (!request.isLive) return;
    final started = position;
    _audioWatchdog = Timer(const Duration(seconds: 6), () async {
      if (!mounted || _audioWarned) return;
      if (currentTrack.audio.id == 'no' || tracks.audio.length <= 1) return; // source genuinely has no audio track
      if (position <= started) return; // picture itself isn't running yet — not an audio-specific issue
      try {
        final native = player.platform;
        if (native is! NativePlayer) return;
        final pts = await native.getProperty('audio-pts');
        if (pts.isEmpty && mounted) {
          _audioWarned = true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No audio detected on this channel — the source itself has no working audio track.')),
          );
        }
      } catch (_) {}
    });
  }

  void _onEnded() {
    if (request.isLive) return;
    _saveProgress(force: true);
    final list = request.playlist;
    if (widget.state.autoNext && list != null && request.playlistIndex >= 0 && request.playlistIndex + 1 < list.length) {
      final next = list[request.playlistIndex + 1];
      setState(() {
        request = next;
        resumed = false;
      });
      _startPlayback();
    }
  }

  void _startHistoryTimer() {
    saveTimer?.cancel();
    if (request.isLive) return;
    saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
  }

  void _saveProgress({bool force = false}) {
    if (request.isLive) return;
    final dur = duration.inMilliseconds / 1000.0;
    final pos = position.inMilliseconds / 1000.0;
    if (dur > 0 && (force || pos > 0)) {
      widget.state.upsertHistory(request, resumeAt: pos, duration: dur);
    }
  }

  void _armHideTimer() {
    hideTimer?.cancel();
    setState(() => controlsVisible = true);
    hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => controlsVisible = false);
    });
  }

  // A tap while the controls are already showing hides them right away
  // (standard behaviour in every other video player) instead of just
  // resetting the same 4-second auto-hide timer, which made a second tap
  // look like it did nothing.
  void _toggleControls() {
    if (controlsVisible && error == null) {
      hideTimer?.cancel();
      setState(() => controlsVisible = false);
    } else {
      _armHideTimer();
    }
  }

  @override
  void dispose() {
    _saveProgress(force: true);
    hideTimer?.cancel();
    saveTimer?.cancel();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _freezeTimer?.cancel();
    _audioWatchdog?.cancel();
    _seekFlashTimer?.cancel();
    _hudTimer?.cancel();
    _bufferSpinnerTimer?.cancel();
    ScreenBrightness().resetScreenBrightness().catchError((_) {});
    _errSub?.cancel();
    _completedSub?.cancel();
    _bufferingSub?.cancel();
    widget.state.downloads.removeListener(_onDownloadsChanged);
    player.dispose();
    if (_slotHeld) widget.state.releaseProviderSlot();
    WakelockPlus.disable();
    if (!widget.request.isLive) widget.state.downloads.playbackEnded();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    super.dispose();
  }

  void _back() => widget.state.closePlayer();

  String _fmt(Duration d) {
    if (d.isNegative) return '00:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
  }

  void _skip(int seconds) {
    final target = position + Duration(seconds: seconds);
    player.seek(target < Duration.zero ? Duration.zero : target);
    _armHideTimer();
  }

  // Double-tap the left/right half of the screen to jump back/forward 10s —
  // same gesture every mainstream video app uses — without touching or
  // showing the control overlay at all, so it works whether or not the seek
  // bar is currently visible.
  void _handleDoubleTapSeek() {
    final x = _doubleTapX;
    if (x == null) return;
    final width = MediaQuery.of(context).size.width;
    final seconds = x < width / 2 ? -10 : 10;
    _skip(seconds);
    _seekFlashTimer?.cancel();
    setState(() => _seekFlash = seconds);
    _seekFlashTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekFlash = null);
    });
  }

  // Vertical swipe on the left half adjusts screen brightness, the right
  // half adjusts volume — the same split every mainstream video app uses —
  // instead of only offering the small speaker-icon slider that was there
  // before.
  Future<void> _onVDragStart(DragStartDetails d) async {
    final width = MediaQuery.of(context).size.width;
    _dragOnLeft = d.localPosition.dx < width / 2;
    if (_dragOnLeft!) {
      try { _dragStartBrightness = await ScreenBrightness().current; } catch (_) { _dragStartBrightness = 0.5; }
    } else {
      _dragStartVolume = await player.stream.volume.first;
    }
  }

  void _onVDragUpdate(DragUpdateDetails d) {
    final height = MediaQuery.of(context).size.height;
    final delta = -d.delta.dy / height;
    if (_dragOnLeft == true) {
      _dragStartBrightness = (_dragStartBrightness + delta).clamp(0.0, 1.0);
      ScreenBrightness().setScreenBrightness(_dragStartBrightness).catchError((_) {});
      setState(() => _hudBrightness = _dragStartBrightness);
    } else if (_dragOnLeft == false) {
      _dragStartVolume = (_dragStartVolume + delta * 100).clamp(0.0, 100.0);
      player.setVolume(_dragStartVolume);
      setState(() => _hudVolume = _dragStartVolume);
    }
  }

  void _onVDragEnd(DragEndDetails d) {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() { _hudBrightness = null; _hudVolume = null; });
    });
  }

  void _toggleFavorite() {
    if (widget.favItem == null || widget.favSection == null) return;
    widget.state.toggleFavorite(widget.favSection!, widget.favItem!);
    setState(() {});
  }

  void _startDownload() {
    widget.state.downloads.add(url: request.url, title: request.title, subtitle: request.subtitle, type: request.type, thumb: request.thumb);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to Downloads — it will download in the background.')));
  }

  // Same live progress-ring/pause-resume/check widget as the episode list in
  // series_screen.dart — tapping it while a download is running now actually
  // pauses it and the icon changes immediately, instead of the old behaviour
  // where it was a static icon and a second tap just popped a "Already in
  // your Downloads list" snackbar with no way to stop it from here.
  Widget _downloadButton(DownloadItem? dl) {
    if (dl == null) {
      return _topIcon(Icons.download_outlined, Colors.white, _startDownload);
    }
    if (dl.status == 'completed') {
      return const Padding(
        padding: EdgeInsets.only(left: 4, right: 4),
        child: Icon(Icons.check_circle, color: AppColors.success, size: 24),
      );
    }
    if (dl.status == 'downloading' || dl.status == 'queued' || dl.status == 'waiting') {
      final pct = (dl.progress * 100).floor();
      return Padding(
        padding: const EdgeInsets.only(left: 4, right: 4),
        child: GestureDetector(
          onTap: () => widget.state.downloads.pause(dl.id),
          child: SizedBox(
            width: 30, height: 30,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 26, height: 26,
                  child: dl.status == 'downloading'
                      ? CircularProgressIndicator(value: dl.progress > 0 ? dl.progress : null, strokeWidth: 2.5, color: const Color(0xFFEF3F66), backgroundColor: Colors.white24)
                      : const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white54, backgroundColor: Colors.white24),
                ),
                dl.status == 'downloading'
                    ? Text('$pct', style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.white))
                    : const Icon(Icons.pause, size: 11, color: Colors.white70),
              ],
            ),
          ),
        ),
      );
    }
    return _topIcon(dl.status == 'failed' ? Icons.refresh : Icons.play_arrow, const Color(0xFFEF3F66), () => widget.state.downloads.resume(dl.id));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mini) return _buildMiniBody();
    return BackButtonListener(
      // Not a routed screen anymore (see AppState.playerLaunch), so the
      // hardware back button has nothing to pop — without this it would fall
      // through to whatever screen is underneath while the full-screen player
      // stayed on top. Matches the on-screen Back button: closes playback.
      onBackButtonPressed: () async {
        widget.state.closePlayer();
        return true;
      },
      child: PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _toggleControls,
          onDoubleTapDown: (d) => _doubleTapX = d.localPosition.dx,
          onDoubleTap: request.isLive ? null : _handleDoubleTapSeek,
          onVerticalDragStart: _onVDragStart,
          onVerticalDragUpdate: _onVDragUpdate,
          onVerticalDragEnd: _onVDragEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: _buildVideo()),
              if (error == null && !loading && _showBufferSpinner)
                const Center(
                  child: SizedBox(width: 34, height: 34, child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 3)),
                ),
              if (_hudBrightness != null || _hudVolume != null)
                Align(
                  alignment: _hudBrightness != null ? Alignment.centerLeft : Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_hudBrightness != null ? Icons.brightness_6 : Icons.volume_up, color: Colors.white, size: 22),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 60, height: 4,
                          child: LinearProgressIndicator(
                            value: _hudBrightness ?? (_hudVolume! / 100),
                            backgroundColor: Colors.white24,
                            color: AppColors.accent,
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              if (_seekFlash != null)
                Align(
                  alignment: _seekFlash! < 0 ? Alignment.centerLeft : Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(30)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_seekFlash! < 0 ? Icons.fast_rewind : Icons.fast_forward, color: Colors.white, size: 22),
                        const SizedBox(width: 6),
                        Text('${_seekFlash!.abs()}s', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ),
              if (controlsVisible || error != null) _buildOverlay(),
            ],
          ),
        ),
      ),
      ),
    );
  }

  // Small floating PiP box: just the picture plus a close/expand/play-pause
  // affordance. No seek bar, no track menu, no gestures — those need real
  // screen space. Tapping the video itself expands back to full screen using
  // the exact same Player/connection (see the GlobalKey note on
  // AppState.PlayerLaunch), so nothing reconnects.
  Widget _buildMiniBody() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: Colors.black,
        child: GestureDetector(
          onTap: () => widget.state.expandPlayer(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildVideo(),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: widget.state.closePlayer,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
              if (error == null && !loading)
                Positioned(
                  bottom: 2,
                  left: 2,
                  child: GestureDetector(
                    onTap: () => playing ? player.pause() : player.play(),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 14, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideo() {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.textDim, size: 36),
            const SizedBox(height: 12),
            Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _retry, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (loading) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.accent),
          SizedBox(height: 12),
          Text('Loading...', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      );
    }
    return Video(controller: videoController, controls: NoVideoControls, fit: videoFit);
  }

  Widget _buildOverlay() {
    final isLive = request.isLive;
    final pos = seeking ? Duration(milliseconds: dragValue.toInt()) : position;
    final dur = duration;
    // `buffered` can briefly read behind the actual playhead right after a
    // seek (mpv resets its cache-time report until the new position starts
    // filling again) — clamping it to at least the current position stops
    // the bar from ever visibly shrinking behind where the video already is.
    final rawBufferedFrac = dur.inMilliseconds > 0 ? (buffered.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    final posFrac = dur.inMilliseconds > 0 ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    final bufferedFrac = rawBufferedFrac < posFrac ? posFrac : rawBufferedFrac;
    final faved = widget.favItem != null && widget.favSection != null && widget.state.isFavorite(widget.favSection!, widget.favItem!);
    final canDownload = request.downloadable;
    final dl = canDownload ? widget.state.downloads.byUrl(request.url) : null;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black87],
          stops: [0, 0.2, 0.75, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _back,
                    icon: const Icon(Icons.arrow_back_ios, size: 14, color: Colors.white),
                    label: const Text('Back', style: TextStyle(color: Colors.white)),
                    style: TextButton.styleFrom(backgroundColor: Colors.black38),
                  ),
                  const Spacer(),
                  if (canDownload) _downloadButton(dl),
                  _topIcon(Icons.picture_in_picture_alt, Colors.white, () => widget.state.minimizePlayer()),
                  _topIcon(Icons.aspect_ratio, Colors.white, _openFitMenu),
                  if (tracks.audio.length > 2 || tracks.subtitle.length > 1 || tracks.video.length > 2) _topIcon(Icons.subtitles_outlined, Colors.white, _openTracksMenu),
                  if (widget.favItem != null)
                    _topIcon(faved ? Icons.favorite : Icons.favorite_border, faved ? const Color(0xFFFF5D7A) : Colors.white, _toggleFavorite),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isLive)
                    Row(
                      children: [
                        Text(_fmt(pos), style: const TextStyle(color: Colors.white, fontSize: 11)),
                        Expanded(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                height: 4,
                                margin: const EdgeInsets.symmetric(horizontal: 8),
                                decoration: BoxDecoration(color: Colors.white.withOpacity(.18), borderRadius: BorderRadius.circular(2)),
                                child: FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: bufferedFrac,
                                  child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2))),
                                ),
                              ),
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  activeTrackColor: AppColors.accent,
                                  inactiveTrackColor: Colors.transparent,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                  thumbColor: AppColors.accent,
                                  overlayShape: SliderComponentShape.noOverlay,
                                ),
                                child: Slider(
                                  value: dur.inMilliseconds > 0 ? pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble() : 0,
                                  max: dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1,
                                  onChangeStart: (v) => setState(() { seeking = true; dragValue = v; }),
                                  onChanged: dur.inMilliseconds > 0 ? (v) => setState(() => dragValue = v) : null,
                                  onChangeEnd: (v) {
                                    player.seek(Duration(milliseconds: v.toInt()));
                                    setState(() => seeking = false);
                                    _armHideTimer();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(_fmt(dur), style: const TextStyle(color: Colors.white, fontSize: 11)),
                      ],
                    )
                  else
                    Row(
                      children: const [
                        Icon(Icons.circle, size: 8, color: Colors.redAccent),
                        SizedBox(width: 5),
                        Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                        onPressed: () { playing ? player.pause() : player.play(); _armHideTimer(); },
                      ),
                      if (!isLive) ...[
                        IconButton(icon: const Icon(Icons.replay_10, color: Colors.white), onPressed: () => _skip(-widget.state.seekStep)),
                        IconButton(icon: const Icon(Icons.forward_10, color: Colors.white), onPressed: () => _skip(widget.state.seekStep)),
                      ],
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '${request.title}${request.subtitle.isNotEmpty ? ' · ${request.subtitle}' : ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ),
                      if (!isLive)
                        PopupMenuButton<double>(
                          color: AppColors.bg3,
                          initialValue: speed,
                          onSelected: (v) { speed = v; player.setRate(v); setState(() {}); },
                          itemBuilder: (context) => speeds.map((s) => PopupMenuItem(value: s, child: Text('${s}x', style: const TextStyle(color: Colors.white)))).toList(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(6)),
                            child: Text('${speed}x', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ),
                      _buildVolumeControl(),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _showVolumeSlider = false;

  // Tapping the speaker opens a small vertical slider above it (rather than
  // just toggling mute), so volume can actually be adjusted from the player
  // the way the rest of the controls work.
  Widget _buildVolumeControl() {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: 100,
      builder: (context, snap) {
        final v = snap.data ?? 100;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showVolumeSlider)
              Container(
                width: 34, height: 110,
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: AppColors.accent,
                      inactiveTrackColor: Colors.white24,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      thumbColor: AppColors.accent,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: v.clamp(0, 100),
                      min: 0, max: 100,
                      onChanged: (nv) => player.setVolume(nv),
                    ),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(v == 0 ? Icons.volume_off : v < 50 ? Icons.volume_down : Icons.volume_up, color: Colors.white),
              onPressed: () {
                setState(() => _showVolumeSlider = !_showVolumeSlider);
                _armHideTimer();
              },
            ),
          ],
        );
      },
    );
  }

  Widget _topIcon(IconData icon, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(icon: Icon(icon, color: color), onPressed: onTap),
    );
  }

  // Bottom sheet defaults to a fixed, non-scrolling size — fine in portrait,
  // but this player is landscape-locked, and a short landscape screen with a
  // long audio+subtitle+video list has no room to show it all: the bottom of
  // the list (often the whole SUBTITLES section) just got clipped off-screen
  // with no way to reach it. isScrollControlled + a real ScrollView fixes
  // that regardless of how many tracks a stream carries.
  void _openTracksMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tracks.video.length > 2) ...[
                  const Padding(padding: EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text('RESOLUTION', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5))),
                  ...tracks.video.where((t) => t.id != 'no').map((t) => ListTile(
                        title: Text(_trackLabel(t.title, _videoTrackDetail(t), t.id)),
                        trailing: currentTrack.video.id == t.id ? const Icon(Icons.check, color: AppColors.accent) : null,
                        onTap: () { player.setVideoTrack(t); Navigator.pop(context); },
                      )),
                ],
                if (tracks.audio.length > 2) ...[
                  const Padding(padding: EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text('AUDIO', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5))),
                  ...tracks.audio.where((t) => t.id != 'no').map((t) => ListTile(
                        title: Text(_trackLabel(t.title, t.language, t.id)),
                        trailing: currentTrack.audio.id == t.id ? const Icon(Icons.check, color: AppColors.accent) : null,
                        onTap: () { player.setAudioTrack(t); Navigator.pop(context); },
                      )),
                ],
                if (tracks.subtitle.length > 1) ...[
                  const Padding(padding: EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text('SUBTITLES', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5))),
                  ListTile(
                    title: const Text('Off'),
                    trailing: currentTrack.subtitle.id == 'no' ? const Icon(Icons.check, color: AppColors.accent) : null,
                    onTap: () { player.setSubtitleTrack(SubtitleTrack.no()); Navigator.pop(context); },
                  ),
                  ...tracks.subtitle.where((t) => t.id != 'no' && t.id != 'auto').map((t) => ListTile(
                        title: Text(_trackLabel(t.title, t.language, t.id)),
                        trailing: currentTrack.subtitle.id == t.id ? const Icon(Icons.check, color: AppColors.accent) : null,
                        onTap: () { player.setSubtitleTrack(t); Navigator.pop(context); },
                      )),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _videoTrackDetail(VideoTrack t) {
    if (t.w != null && t.h != null && t.w! > 0 && t.h! > 0) return '${t.w}x${t.h}';
    return t.language;
  }

  // Cycles the video's fill mode instead of just always fitting the native
  // ratio — some sources are mastered with black bars baked in or an odd
  // aspect ratio, and users expect a way to zoom/stretch to fill a 16:9
  // screen the way every other player offers.
  void _openFitMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _fitLabels.entries.map((e) => ListTile(
                title: Text(e.value),
                trailing: videoFit == e.key ? const Icon(Icons.check, color: AppColors.accent) : null,
                onTap: () { setState(() => videoFit = e.key); Navigator.pop(context); },
              )).toList(),
        ),
      ),
    );
  }

  String _trackLabel(String? title, String? lang, String id) {
    if (title != null && title.trim().isNotEmpty) return title;
    if (lang != null && lang.trim().isNotEmpty) return lang.toUpperCase();
    return 'Track $id';
  }
}
