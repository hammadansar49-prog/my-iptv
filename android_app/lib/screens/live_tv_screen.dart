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

class _LiveTvScreenState extends State<LiveTvScreen> {
  late final Player player;
  late final VideoController videoController;
  late PlayableItem current;
  bool fullscreen = false;
  bool playing = true;
  bool loading = true;
  String? error;
  String search = '';
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _stallTimer;
  Duration position = Duration.zero;
  StreamSubscription? _errSub;

  @override
  void initState() {
    super.initState();
    current = widget.initial;
    player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024));
    videoController = VideoController(player, configuration: const VideoControllerConfiguration(hwdec: 'no'));
    player.stream.playing.listen((p) => mounted ? setState(() => playing = p) : null);
    player.stream.position.listen((p) => mounted ? setState(() => position = p) : null);
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
    } catch (e) {
      if (!mounted) return;
      _handleFailure('It may be offline or blocked by the provider.');
    }
  }

  void _handleFailure(String reason) {
    _stallTimer?.cancel();
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

  void _toggleFullscreen() {
    setState(() => fullscreen = !fullscreen);
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _errSub?.cancel();
    player.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && fullscreen) _toggleFullscreen();
      },
      child: fullscreen ? _buildFullscreen() : _buildInline(),
    );
  }

  Widget _buildInline() {
    final list = search.isEmpty ? widget.channels : widget.channels.where((c) => c.name.toLowerCase().contains(search.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: Text(current.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              Container(color: Colors.black, child: _buildVideo()),
              if (!loading && error == null) _buildInlineControls(),
            ]),
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
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, i) {
                final ch = list[i];
                final active = ch.id == current.id;
                return ListTile(
                  selected: active,
                  selectedTileColor: AppColors.bg2,
                  leading: Artwork(url: ch.thumb, title: '', width: 48, radius: 6, fit: BoxFit.contain, placeholderIcon: Icons.live_tv),
                  title: Text(ch.name, style: TextStyle(fontSize: 13, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? AppColors.accent : AppColors.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: active
                      ? Icon(playing ? Icons.equalizer : Icons.pause, color: AppColors.accent, size: 18)
                      : IconButton(
                          icon: Icon(widget.state.isFavorite('live', ch) ? Icons.favorite : Icons.favorite_border, size: 18, color: widget.state.isFavorite('live', ch) ? const Color(0xFFFF5D7A) : AppColors.textDim),
                          onPressed: () async { await widget.state.toggleFavorite('live', ch); setState(() {}); },
                        ),
                  onTap: active ? null : () => _open(ch),
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
        _roundIcon(Icons.fullscreen, _toggleFullscreen),
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

  Widget _buildFullscreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideo(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _toggleFullscreen,
                    icon: const Icon(Icons.fullscreen_exit, size: 16, color: Colors.white),
                    label: const Text('Exit fullscreen', style: TextStyle(color: Colors.white)),
                    style: TextButton.styleFrom(backgroundColor: Colors.black38),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                    child: Text(current.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
          if (!loading && error == null)
            Positioned(
              left: 0, right: 0, bottom: 20,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _roundIcon(playing ? Icons.pause : Icons.play_arrow, () => playing ? player.pause() : player.play()),
              ]),
            ),
        ],
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
