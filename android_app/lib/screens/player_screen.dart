import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
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

  const PlayerScreen({
    super.key,
    required this.state,
    required this.request,
    this.favSection,
    this.favItem,
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

  StreamSubscription? _errSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _bufferingSub;
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _stallTimer;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  Duration buffered = Duration.zero;
  bool playing = false;
  bool buffering = true;
  Tracks tracks = const Tracks();
  Track currentTrack = const Track();

  @override
  void initState() {
    super.initState();
    request = widget.request;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
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
    _startPlayback();
    _armHideTimer();
  }

  void _wireStreams() {
    player.stream.position.listen((p) => mounted ? setState(() => position = p) : null);
    player.stream.duration.listen((d) => mounted ? setState(() => duration = d) : null);
    player.stream.buffer.listen((b) => mounted ? setState(() => buffered = b) : null);
    player.stream.playing.listen((p) => mounted ? setState(() => playing = p) : null);
    _bufferingSub = player.stream.buffering.listen((b) => mounted ? setState(() => buffering = b) : null);
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
      // A live channel whose open() succeeds but never actually delivers a
      // frame (some providers accept the connection then go silent) is
      // covered the same way — one more retry rather than sitting on a
      // spinner forever.
      if (request.isLive) {
        _stallTimer?.cancel();
        _stallTimer = Timer(const Duration(seconds: 12), () {
          if (mounted && position == Duration.zero && !playing) _handleFailure('No response from the channel.');
        });
      }
    } catch (e) {
      if (!mounted) return;
      _handleFailure('It may be offline or blocked by the provider.');
    }
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

  @override
  void dispose() {
    _saveProgress(force: true);
    hideTimer?.cancel();
    saveTimer?.cancel();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _errSub?.cancel();
    _completedSub?.cancel();
    _bufferingSub?.cancel();
    player.dispose();
    WakelockPlus.disable();
    if (!widget.request.isLive) widget.state.downloads.playbackEnded();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    super.dispose();
  }

  void _back() => Navigator.of(context).pop();

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

  void _toggleFavorite() {
    if (widget.favItem == null || widget.favSection == null) return;
    widget.state.toggleFavorite(widget.favSection!, widget.favItem!);
    setState(() {});
  }

  void _download() {
    if (!request.downloadable) return;
    final existing = widget.state.downloads.byUrl(request.url);
    if (existing != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        existing.status == 'completed' ? 'Already downloaded.' : 'Already in your Downloads list.',
      )));
      return;
    }
    widget.state.downloads.add(url: request.url, title: request.title, subtitle: request.subtitle, type: request.type, thumb: request.thumb);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to Downloads — it will download in the background.')));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _armHideTimer,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: _buildVideo()),
              if (error == null && !loading && buffering)
                const Center(
                  child: SizedBox(width: 34, height: 34, child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 3)),
                ),
              if (controlsVisible || error != null) _buildOverlay(),
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
            ElevatedButton(onPressed: () { _retries = 0; _startPlayback(); }, child: const Text('Retry')),
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
    return Video(controller: videoController, controls: NoVideoControls, fit: BoxFit.contain);
  }

  Widget _buildOverlay() {
    final isLive = request.isLive;
    final pos = seeking ? Duration(milliseconds: dragValue.toInt()) : position;
    final dur = duration;
    final bufferedFrac = dur.inMilliseconds > 0 ? (buffered.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;
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
                  if (canDownload)
                    _topIcon(
                      dl == null ? Icons.download_outlined : dl.status == 'completed' ? Icons.download_done : Icons.downloading,
                      dl?.status == 'downloading' ? const Color(0xFFEF3F66) : Colors.white,
                      _download,
                    ),
                  if (tracks.audio.length > 2 || tracks.subtitle.length > 1) _topIcon(Icons.subtitles_outlined, Colors.white, _openTracksMenu),
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
                                  child: Container(decoration: BoxDecoration(color: Colors.white.withOpacity(.5), borderRadius: BorderRadius.circular(2))),
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

  void _openTracksMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
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
