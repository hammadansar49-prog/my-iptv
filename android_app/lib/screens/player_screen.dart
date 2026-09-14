import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';

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
  VideoPlayerController? controller;
  bool loading = true;
  String? error;
  bool controlsVisible = true;
  Timer? hideTimer;
  Timer? saveTimer;
  bool resumed = false;
  double speed = 1.0;
  static const speeds = [0.5, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WakelockPlus.enable();
    _startPlayback();
    _armHideTimer();
  }

  Future<void> _startPlayback() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.request.url));
      controller = c;
      await c.initialize().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Stream took too long to start.'),
      );
      c.addListener(_onTick);
      await c.setPlaybackSpeed(speed);
      await c.play();
      if (!widget.request.isLive && widget.request.resumeAt > 5 && !resumed) {
        final dur = c.value.duration;
        if (widget.request.resumeAt < dur.inSeconds * 0.97) {
          await c.seekTo(Duration(seconds: widget.request.resumeAt.toInt()));
        }
        resumed = true;
      }
      setState(() => loading = false);
      _startHistoryTimer();
    } catch (e) {
      setState(() {
        loading = false;
        error = 'This stream could not be played.\nIt may use a format not supported on this device.';
      });
    }
  }

  void _onTick() {
    if (!mounted) return;
    final c = controller;
    if (c == null) return;
    if (c.value.hasError && error == null) {
      setState(() => error = 'Playback error — the stream may have stopped.');
    }
    setState(() {}); // keep the seek bar / time labels live
  }

  void _startHistoryTimer() {
    saveTimer?.cancel();
    if (widget.request.isLive) return;
    saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
  }

  void _saveProgress() {
    final c = controller;
    if (c == null || !c.value.isInitialized || widget.request.isLive) return;
    final dur = c.value.duration.inMilliseconds / 1000.0;
    final pos = c.value.position.inMilliseconds / 1000.0;
    if (dur > 0) {
      widget.state.upsertHistory(widget.request, resumeAt: pos, duration: dur);
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
    _saveProgress();
    hideTimer?.cancel();
    saveTimer?.cancel();
    controller?.removeListener(_onTick);
    controller?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  void _back() {
    Navigator.of(context).pop();
  }

  String _fmt(Duration d) {
    if (d.isNegative) return '00:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$mm:$ss' : '$mm:$ss';
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
              if (controller?.value.isInitialized == true && controller!.value.isBuffering)
                const Center(
                  child: SizedBox(
                    width: 34, height: 34,
                    child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 3),
                  ),
                ),
              if (controlsVisible) _buildOverlay(),
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
            ElevatedButton(onPressed: _startPlayback, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (loading || controller == null || !controller!.value.isInitialized) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppColors.accent),
          SizedBox(height: 12),
          Text('Loading...', style: TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      );
    }
    return AspectRatio(
      aspectRatio: controller!.value.aspectRatio == 0 ? 16 / 9 : controller!.value.aspectRatio,
      child: VideoPlayer(controller!),
    );
  }

  Widget _buildOverlay() {
    final c = controller;
    final initialized = c != null && c.value.isInitialized;
    final isLive = widget.request.isLive;
    final pos = initialized ? c.value.position : Duration.zero;
    final dur = initialized ? c.value.duration : Duration.zero;
    double bufferedFrac = 0;
    if (initialized && dur.inMilliseconds > 0 && c.value.buffered.isNotEmpty) {
      final end = c.value.buffered.map((r) => r.end).reduce((a, b) => a > b ? a : b);
      bufferedFrac = (end.inMilliseconds / dur.inMilliseconds).clamp(0, 1);
    }
    final faved = widget.favItem != null && widget.favSection != null
        ? widget.state.isFavorite(widget.favSection!, widget.favItem!)
        : false;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black87],
          stops: [0, 0.2, 0.75, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar
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
                  if (widget.favItem != null)
                    IconButton(
                      icon: Icon(faved ? Icons.favorite : Icons.favorite_border, color: faved ? const Color(0xFFFF5D7A) : Colors.white),
                      onPressed: () async {
                        await widget.state.toggleFavorite(widget.favSection!, widget.favItem!);
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
            const Spacer(),
            // Bottom controls
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
                                  onChanged: initialized ? (v) => c.seekTo(Duration(milliseconds: v.toInt())) : null,
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
                        icon: Icon(initialized && c.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                        onPressed: initialized ? () => setState(() => c.value.isPlaying ? c.pause() : c.play()) : null,
                      ),
                      if (!isLive) ...[
                        IconButton(
                          icon: const Icon(Icons.replay_10, color: Colors.white),
                          onPressed: initialized ? () => c.seekTo(pos - const Duration(seconds: 10)) : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.forward_10, color: Colors.white),
                          onPressed: initialized ? () => c.seekTo(pos + const Duration(seconds: 10)) : null,
                        ),
                      ],
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '${widget.request.title}${widget.request.subtitle.isNotEmpty ? ' · ${widget.request.subtitle}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ),
                      ),
                      PopupMenuButton<double>(
                        color: AppColors.bg3,
                        initialValue: speed,
                        onSelected: (v) async {
                          speed = v;
                          await controller?.setPlaybackSpeed(v);
                          setState(() {});
                        },
                        itemBuilder: (context) => speeds
                            .map((s) => PopupMenuItem(value: s, child: Text('${s}x', style: const TextStyle(color: Colors.white))))
                            .toList(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(6)),
                          child: Text('${speed}x', style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      ),
                      IconButton(
                        icon: Icon(initialized && c.value.volume == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                        onPressed: initialized
                            ? () => setState(() => c.setVolume(c.value.volume == 0 ? 1 : 0))
                            : null,
                      ),
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
}
