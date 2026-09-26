import 'dart:async';
import '../../core/utils/app_orientation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../../services/player/playback_request.dart';
import '../../services/player/player_controller.dart';
import '../../services/player/live_pip_mixin.dart';
import '../providers.dart';
import '../widgets/category_strip.dart';
import '../widgets/error_banner.dart';
import 'live_channel_row.dart';

/// Inline, YouTube-style Live TV: video pinned to the top, channel list
/// below, and ONE [PlayerController] reused for every channel switch.
///
/// This shape is locked by CLAUDE.md — the previous app routed live taps into
/// a separate full player screen and paid for it with a reload on every
/// channel change. Fullscreen is a layout change in place, not a route push,
/// so playback never restarts when the user expands the video.
class LiveTvScreen extends ConsumerStatefulWidget {
  const LiveTvScreen({super.key, this.initialChannel});

  final LiveChannel? initialChannel;

  @override
  ConsumerState<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends ConsumerState<LiveTvScreen>
    with LivePipMixin<LiveTvScreen> {
  @override
  PlayerController? get pipPlayer => _player;

  PlayerController? _player;
  LiveChannel? _current;
  bool _fullscreen = false;
  String _query = '';
  Timer? _debounce;

  /// The search for [_query], started once per query. Creating it inside
  /// build() restarted it on every rebuild — and the inline player rebuilds
  /// this screen continuously while a channel plays — so the results list
  /// sat on its spinner forever.
  Future<List<LiveChannel>>? _search;
  String? _searchFor;

  Future<List<LiveChannel>> _searchResults() {
    if (_search == null || _searchFor != _query) {
      _searchFor = _query;
      _search = ref.read(contentRepositoryProvider)?.searchChannels(_query) ??
          Future.value(const <LiveChannel>[]);
    }
    return _search!;
  }
  final _searchController = TextEditingController();

  /// Guards against a burst of channel taps queueing several opens.
  int _switchToken = 0;

  late final bool _isTv;

  @override
  void initState() {
    super.initState();
    initLivePip();
    _isTv = ref.read(isTvProvider); // ref is unusable in dispose()
    final initial = widget.initialChannel;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play(initial));
    }
  }

  @override
  void dispose() {
    disposeLivePip();
    _debounce?.cancel();
    _searchController.dispose();
    // Spec §25: the player and everything it owns goes with the screen.
    unawaited(_player?.dispose());
    unawaited(WakelockPlus.disable());
    unawaited(AppOrientation.restore(isTv: _isTv));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  PlayerController _ensurePlayer() {
    return _player ??= PlayerController(
      guard: ref.read(connectionGuardProvider),
    )..addListener(_onPlayerChanged);
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
    syncLivePip();
  }

  Future<void> _play(LiveChannel channel) async {
    // OK on the channel that is already playing = fullscreen (TV remote:
    // the small fullscreen icon on the video is hard to reach).
    if (_current?.streamId == channel.streamId &&
        (_player?.state.hasMedia ?? false)) {
      _toggleFullscreen();
      return;
    }
    final repo = ref.read(contentRepositoryProvider);
    if (repo == null) return;

    final token = ++_switchToken;
    setState(() => _current = channel);

    final player = _ensurePlayer();
    await WakelockPlus.enable();

    // A rapid second tap supersedes this one before the open even starts.
    if (token != _switchToken || !mounted) return;

    await player.open(PlaybackRequest(
      url: repo.liveUrl(channel),
      title: channel.name,
      isLive: true,
      historyKey: channel.key,
      thumb: channel.logo,
      section: ContentSection.live,
      replay: PlaybackRef(
        section: ContentSection.live,
        streamId: '${channel.streamId}',
      ),
    ));

    if (token != _switchToken || !mounted) return;

    // Live history has no position — it is a "recently watched" marker only.
    unawaited(ref.read(libraryRepositoryProvider).recordProgress(
          PlaybackRequest(
            url: repo.liveUrl(channel),
            title: channel.name,
            isLive: true,
            historyKey: channel.key,
            thumb: channel.logo,
            section: ContentSection.live,
          ).toHistoryEntry(),
          position: Duration.zero,
          duration: Duration.zero,
        ));
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      AppOrientation.restore(isTv: ref.read(isTvProvider));
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    // Debounce so a 15,000-channel filter does not run per keystroke.
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final categoryId = ref.watch(selectedCategoryProvider(ContentSection.live));

    // Inside the PiP window: the picture only, no list or chrome.
    if (inPip) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildVideo(expanded: true),
      );
    }

    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        // Back exits fullscreen first, then the screen (spec §52).
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          top: !_fullscreen,
          bottom: !_fullscreen,
          child: _fullscreen
              ? _buildVideo(expanded: true)
              : _wide(context)
              // TV / landscape: video on the left, search + categories +
              // channels on the right — a TV-wide 16:9 player on top left
              // no room for the list or the search field.
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width * 0.42,
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.md),
                        child: _buildVideo(expanded: false),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          ScopedSearchField(
                            controller: _searchController,
                            hint: 'Search channels',
                            onChanged: _onSearchChanged,
                            onClear: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                          if (_query.isEmpty)
                            const CategoryStrip(section: ContentSection.live),
                          Expanded(child: _buildChannelList(categoryId)),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _buildVideo(expanded: false),
                    ScopedSearchField(
                      controller: _searchController,
                      hint: 'Search channels',
                      onChanged: _onSearchChanged,
                      onClear: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
                    if (_query.isEmpty)
                      const CategoryStrip(section: ContentSection.live),
                    Expanded(child: _buildChannelList(categoryId)),
                  ],
                ),
        ),
      ),
    );
  }

  static bool _wide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height && size.width >= 640;
  }

  Widget _buildVideo({required bool expanded}) {
    final player = _player;
    final state = player?.state;

    final video = Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (player?.videoController != null)
            Video(
              controller: player!.videoController!,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),

          if (state == null || !state.hasMedia)
            const Center(
              child: Text(
                'Pick a channel to start watching',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),

          if (state != null &&
              (state.phase == PlaybackPhase.opening ||
                  state.phase == PlaybackPhase.buffering))
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
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
            ),

          if (state != null && state.phase == PlaybackPhase.failed)
            _PlaybackError(
              message: state.error?.message ?? 'Unable to play this stream.',
              onRetry: () => player?.retry(),
            ),

          // Channel name + fullscreen toggle.
          Positioned(
            left: Insets.md,
            right: Insets.md,
            top: Insets.sm,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _current?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                    ),
                  ),
                ),
                livePipButton(hasMedia: state?.hasMedia ?? false),
                IconButton(
                  onPressed: _toggleFullscreen,
                  icon: Icon(
                    expanded
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (expanded) return video;
    return AspectRatio(aspectRatio: 16 / 9, child: video);
  }

  Widget _buildChannelList(String categoryId) {
    if (_query.isNotEmpty) {
      // Scoped search: live channels ONLY (spec §13).
      return FutureBuilder<List<LiveChannel>>(
        future: _searchResults(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final results = snap.data ?? const <LiveChannel>[];
          if (results.isEmpty) {
            return const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No Channels Found',
              message: 'Nothing matches that search in Live TV.',
            );
          }
          return _channelListView(results);
        },
      );
    }

    final async = ref.watch(liveChannelsProvider(categoryId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: ErrorBanner(
          message: 'Could not load channels.',
          onRetry: () => ref.invalidate(liveChannelsProvider(categoryId)),
        ),
      ),
      data: (channels) => channels.isEmpty
          ? const EmptyState(
              icon: Icons.live_tv_outlined,
              title: 'No Channels Found',
              message: 'This category is empty.',
            )
          : _channelListView(channels),
    );
  }

  Widget _channelListView(List<LiveChannel> channels) {
    // ListView.builder keeps only the visible rows alive — mandatory with
    // 15,000+ channels (spec §10/§46).
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Insets.xxl * 3),
      itemCount: channels.length,
      itemExtent: 72,
      itemBuilder: (context, i) {
        final channel = channels[i];
        return LiveChannelRow(
          channel: channel,
          selected: channel.streamId == _current?.streamId,
          onTap: () => _play(channel),
        );
      },
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.danger, size: 34),
          const SizedBox(height: Insets.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: Insets.lg),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
