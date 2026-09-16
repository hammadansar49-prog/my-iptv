import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../app_state.dart';
import '../artwork.dart';
import '../models.dart';
import '../theme.dart';

/// Live TV the way YouTube plays a video: the channel plays inline at the
/// top of the screen with the rest of the channels scrollable underneath —
/// tapping another one switches the SAME player in place, no reload, no
/// leaving the screen. The expand button is what goes fullscreen/landscape;
/// closing fullscreen comes right back to this same inline view.
class LiveTvScreen extends StatefulWidget {
  final AppState state;
  final List<PlayableItem> channels;
  final PlayableItem initial;
  const LiveTvScreen({super.key, required this.state, required this.channels, required this.initial});

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> with SingleTickerProviderStateMixin {
  late final Player player;
  late final VideoController videoController;
  late PlayableItem current;
  bool playing = true;
  bool loading = true;
  String? error;
  String search = '';
  // Was: pause+stop this player, push a brand-new PlayerScreen with a brand-
  // new Player/connection for fullscreen, then reopen a THIRD connection on
  // the way back — the visible "loading again" every time the fullscreen
  // button was pressed. Fullscreen is now just this same widget/State/Player
  // relaid out full-screen-landscape; nothing ever reconnects.
  bool fullscreen = false;

  // Swipe-up-on-the-video "grow" gesture (stays in portrait, unlike the
  // fullscreen/landscape button above) — a continuous 0..1 value driven
  // straight off the drag so the video visibly tracks the finger, then
  // eases to fully open/closed on release. 0 = normal inline height, 1 =
  // expanded to most of the screen.
  late final AnimationController _expandCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  double _dragUnit = 0;

  void _onExpandDragUpdate(DragUpdateDetails d) {
    final h = MediaQuery.of(context).size.height;
    _dragUnit = (_expandCtrl.value - d.delta.dy / (h * 0.4)).clamp(0.0, 1.0);
    _expandCtrl.value = _dragUnit;
  }

  void _onExpandDragEnd(DragEndDetails d) {
    final flingUp = d.velocity.pixelsPerSecond.dy < -400;
    final flingDown = d.velocity.pixelsPerSecond.dy > 400;
    final open = flingUp || (!flingDown && _expandCtrl.value > 0.5);
    _expandCtrl.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
  }
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _stallTimer;
  Timer? _freezeTimer;
  Duration _lastFreezeCheckPos = Duration.zero;
  int _freezeStrikes = 0;
  Timer? _audioWatchdog;
  bool _audioWarned = false;
  Duration position = Duration.zero;
  StreamSubscription? _errSub;
  Tracks tracks = const Tracks();
  Track currentTrack = const Track();

  @override
  void initState() {
    super.initState();
    current = widget.initial;
    player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024));
    videoController = VideoController(player, configuration: const VideoControllerConfiguration(hwdec: 'no'));
    player.stream.playing.listen((p) => mounted ? setState(() => playing = p) : null);
    player.stream.position.listen((p) => mounted ? setState(() => position = p) : null);
    player.stream.tracks.listen((t) => mounted ? setState(() => tracks = t) : null);
    player.stream.track.listen((t) => mounted ? setState(() => currentTrack = t) : null);
    _errSub = player.stream.error.listen((msg) { if (mounted) _handleFailure(msg); });
    WakelockPlus.enable();
    _open(current);
  }

  Future<void> _open(PlayableItem ch) async {
    setState(() {
      current = ch;
      loading = true;
      error = null;
      position = Duration.zero;
    });
    try {
      await player.open(Media(widget.state.liveUrl(ch.id), httpHeaders: const {'User-Agent': 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100'}));
      if (!mounted) return;
      _retries = 0;
      setState(() => loading = false);
      _stallTimer?.cancel();
      _stallTimer = Timer(const Duration(seconds: 12), () {
        if (mounted && position == Duration.zero && !playing) _handleFailure('No response from the channel.');
      });
      _armFreezeWatchdog();
      _armAudioWatchdog();
    } catch (e) {
      if (!mounted) return;
      _handleFailure('It may be offline or blocked by the provider.');
    }
  }

  // Same best-effort audio check as the fullscreen player screen — mpv
  // decodes AC-3/E-AC-3 natively so the PC app's Chromium-specific silent-
  // audio bug mostly doesn't apply here; this only tells the user when a
  // selected audio track never produces a timestamp while the picture runs.
  void _armAudioWatchdog() {
    _audioWatchdog?.cancel();
    _audioWarned = false;
    final started = position;
    _audioWatchdog = Timer(const Duration(seconds: 6), () async {
      if (!mounted || _audioWarned) return;
      if (currentTrack.audio.id == 'no' || tracks.audio.length <= 1) return;
      if (position <= started) return;
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

  // Same stall detection as the VOD/live player screen: some providers keep
  // the connection open but the picture just stops advancing with no error
  // event. First strike nudges with a tiny seek; a second consecutive stall
  // forces a full reconnect.
  void _armFreezeWatchdog() {
    _freezeTimer?.cancel();
    _lastFreezeCheckPos = position;
    _freezeTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      if (!playing) {
        _lastFreezeCheckPos = position;
        return;
      }
      if (position == _lastFreezeCheckPos) {
        _freezeStrikes++;
        if (_freezeStrikes >= 2) {
          _freezeStrikes = 0;
          _handleFailure('The stream stalled.');
        } else {
          player.seek(position + const Duration(milliseconds: 500));
        }
      } else {
        _freezeStrikes = 0;
      }
      _lastFreezeCheckPos = position;
    });
  }

  void _handleFailure(String reason) {
    _stallTimer?.cancel();
    _freezeTimer?.cancel();
    _audioWatchdog?.cancel();
    if (_retries < 3) {
      _retries++;
      setState(() { loading = true; error = null; });
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(milliseconds: 600 * _retries), () => _open(current));
      return;
    }
    setState(() {
      loading = false;
      error = 'This channel is unavailable right now — try another.';
    });
  }

  // Same Player/connection throughout — fullscreen only changes system
  // chrome + orientation + which controls are drawn, never touches the
  // stream itself.
  void _setFullscreen(bool v) {
    setState(() => fullscreen = v);
    if (v) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _freezeTimer?.cancel();
    _audioWatchdog?.cancel();
    _errSub?.cancel();
    _expandCtrl.dispose();
    player.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => fullscreen ? _buildFullscreen() : _buildInline();

  // Same Player/VideoController as the inline view above — just relaid out
  // full-screen with the live-style overlay (no seek bar, matches the
  // fullscreen player screen used for movies/episodes).
  Widget _buildFullscreen() {
    return BackButtonListener(
      onBackButtonPressed: () async {
        _setFullscreen(false);
        return true;
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) { if (!didPop) _setFullscreen(false); },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildVideo(),
              if (!loading && error == null)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(current.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ),
              if (!loading && error == null) _buildInlineControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInline() {
    final list = search.isEmpty ? widget.channels : widget.channels.where((c) => c.name.toLowerCase().contains(search.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: Text(current.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          AnimatedBuilder(
            animation: _expandCtrl,
            builder: (context, child) {
              final screenH = MediaQuery.of(context).size.height;
              final compact = MediaQuery.of(context).size.width * 9 / 16;
              final expanded = screenH * 0.62;
              final h = compact + (expanded - compact) * _expandCtrl.value;
              return SizedBox(height: h, child: child);
            },
            child: GestureDetector(
              onVerticalDragUpdate: _onExpandDragUpdate,
              onVerticalDragEnd: _onExpandDragEnd,
              child: Stack(fit: StackFit.expand, children: [
                Container(color: Colors.black, child: _buildVideo()),
                if (!loading && error == null) _buildInlineControls(),
                if (!loading && error == null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: AnimatedBuilder(
                        animation: _expandCtrl,
                        builder: (context, _) => Icon(
                          _expandCtrl.value > 0.5 ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                          color: Colors.white54,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              onChanged: (v) => setState(() => search = v),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(isDense: true, hintText: 'Search channels...', prefixIcon: Icon(Icons.search, size: 18)),
            ),
          ),
          Expanded(
            // Was a plain ListTile per row with a hairline Divider between
            // them — while artwork was still loading (placeholder tiles,
            // several in a row) that hairline visually read as a second,
            // stray line cutting through an otherwise-empty row ("double
            // line" look). Each row is its own bordered, rounded card now
            // (same style as every other list in the app), so there's no
            // shared divider line to look wrong regardless of load state.
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final ch = list[i];
                final active = ch.id == current.id;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: active ? AppColors.bg3 : AppColors.bg2,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: active ? null : () => _open(ch),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: active ? AppColors.accent : AppColors.border),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            Artwork(url: ch.thumb, title: ch.name, width: 44, radius: 6, fit: BoxFit.contain, placeholderIcon: Icons.live_tv),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(ch.name, style: TextStyle(fontSize: 13, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? AppColors.accent : AppColors.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            const SizedBox(width: 8),
                            active
                                ? Icon(playing ? Icons.equalizer : Icons.pause, color: AppColors.accent, size: 18)
                                : IconButton(
                                    icon: Icon(widget.state.isFavorite('live', ch) ? Icons.favorite : Icons.favorite_border, size: 18, color: widget.state.isFavorite('live', ch) ? const Color(0xFFFF5D7A) : AppColors.textDim),
                                    onPressed: () async { await widget.state.toggleFavorite('live', ch); setState(() {}); },
                                  ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineControls() {
    return Positioned(
      right: 8, bottom: 8,
      child: Row(children: [
        _roundIcon(playing ? Icons.pause : Icons.play_arrow, () => playing ? player.pause() : player.play()),
        const SizedBox(width: 6),
        _roundIcon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, () => _setFullscreen(!fullscreen)),
      ]),
    );
  }

  Widget _roundIcon(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }

  Widget _buildVideo() {
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: AppColors.textDim, size: 30),
            const SizedBox(height: 10),
            Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12)),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: () { _retries = 0; _open(current); }, child: const Text('Retry')),
          ]),
        ),
      );
    }
    if (loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    return Video(controller: videoController, controls: NoVideoControls, fit: BoxFit.contain);
  }
}
