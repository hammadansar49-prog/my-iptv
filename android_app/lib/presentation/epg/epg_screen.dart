import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/epg.dart';
import '../../services/player/playback_request.dart';
import '../../services/player/player_controller.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';

/// Programme guide: inline player on top, a scrolling timeline grid below.
///
/// The grid is the spec's core EPG deliverable (§11–13). Mechanics:
///  * a time ruler in 30-minute slots at a fixed pixels-per-minute scale
///  * one row per channel, its programmes positioned and sized from their
///    real start/end times against that scale
///  * a red "now" line at the current time, moving on one shared clock
///  * horizontal scroll is SHARED between the ruler and every row, so they
///    can never drift apart
///  * rows are built lazily by a ListView.builder with a fixed extent, and
///    each row fetches its own guide once (cached in the repository) — a
///    15,000-channel list never fans out 15,000 requests (§45)
///
/// The player is the same inline arrangement Live TV uses, reusing one
/// Player instance across channel switches (CLAUDE.md).
class EpgScreen extends ConsumerStatefulWidget {
  const EpgScreen({super.key});

  @override
  ConsumerState<EpgScreen> createState() => _EpgScreenState();
}

class _EpgScreenState extends ConsumerState<EpgScreen> {
  /// Layout scale for the timeline.
  static const _pxPerMinute = 4.0;
  static const _slotMinutes = 30;
  static const _slotWidth = _slotMinutes * _pxPerMinute;
  static const _channelColumnWidth = 132.0;
  static const _rowHeight = 68.0;

  /// How far back the timeline starts relative to now, and how far it runs.
  static const _hoursBefore = 1;
  static const _hoursTotal = 12;

  PlayerController? _player;
  LiveChannel? _current;
  int _switchToken = 0;

  /// One clock for the whole screen — not one per row (spec §47).
  Timer? _clock;
  DateTime _now = DateTime.now();

  /// Shared horizontal scroll for the ruler and all channel rows.
  final _timelineController = ScrollController();
  final _rowsController = ScrollController();

  late DateTime _origin;

  @override
  void initState() {
    super.initState();
    _origin = _alignToSlot(DateTime.now().subtract(
      const Duration(hours: _hoursBefore),
    ));
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });

    // Open the timeline near "now" rather than at the far left.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_timelineController.hasClients) return;
      final offset = _offsetFor(DateTime.now()) - 120;
      _timelineController.jumpTo(
        offset.clamp(0, _timelineController.position.maxScrollExtent),
      );
    });
  }

  static DateTime _alignToSlot(DateTime t) {
    final minute = (t.minute ~/ _slotMinutes) * _slotMinutes;
    return DateTime(t.year, t.month, t.day, t.hour, minute);
  }

  double _offsetFor(DateTime t) =>
      t.difference(_origin).inMinutes * _pxPerMinute;

  double get _timelineWidth => _hoursTotal * 60 * _pxPerMinute;

  @override
  void dispose() {
    _clock?.cancel();
    _timelineController.dispose();
    _rowsController.dispose();
    unawaited(_player?.dispose());
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  PlayerController _ensurePlayer() {
    return _player ??= PlayerController(
      guard: ref.read(connectionGuardProvider),
      http: ref.read(httpClientProvider),
    )..addListener(_onPlayerChanged);
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _play(LiveChannel channel) async {
    final repo = ref.read(contentRepositoryProvider);
    if (repo == null) return;
    final token = ++_switchToken;
    setState(() => _current = channel);

    final player = _ensurePlayer();
    await WakelockPlus.enable();
    if (token != _switchToken || !mounted) return;

    await player.open(PlaybackRequest(
      url: repo.liveUrl(channel),
      title: channel.name,
      isLive: true,
      historyKey: channel.key,
      thumb: channel.logo,
      section: ContentSection.live,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final categoryId = ref.watch(selectedCategoryProvider(ContentSection.live));
    final async = ref.watch(liveChannelsProvider(categoryId));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildPlayer(),
            _buildRuler(),
            Expanded(
              child: async.when(
                loading: () => const _GuideSkeleton(),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(Insets.lg),
                  child: ErrorBanner(
                    message: 'Could not load the guide.',
                    onRetry: () =>
                        ref.invalidate(liveChannelsProvider(categoryId)),
                  ),
                ),
                data: (channels) => channels.isEmpty
                    ? const EmptyState(
                        icon: Icons.grid_view_outlined,
                        title: 'No Channels Found',
                        message: 'This category is empty.',
                      )
                    : _buildGrid(channels),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    final player = _player;
    final state = player?.state;
    final channel = _current;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
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
                  'Pick a channel from the guide',
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
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent),
                    ),
                    SizedBox(width: Insets.md),
                    Text('Buffering...',
                        style: TextStyle(color: Colors.white, fontSize: 18)),
                  ],
                ),
              ),

            if (state != null && state.phase == PlaybackPhase.failed)
              Container(
                color: Colors.black.withValues(alpha: 0.75),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(Insets.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      state.error?.message ?? 'Unable to play this stream.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: Insets.md),
                    FilledButton(
                      onPressed: () => player?.retry(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),

            // Catch-up. Only offered when the panel says this channel has
            // an archive — `tv_archive` + `tv_archive_duration` (spec: do
            // not fake it).
            if (channel != null && channel.hasCatchup)
              Positioned(
                top: Insets.md,
                right: Insets.md,
                child: _CatchupPill(
                  days: channel.tvArchiveDuration,
                  onTap: () => ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      content: Text(
                        '${channel.name} keeps ${channel.tvArchiveDuration} '
                        'day(s) of catch-up. Playback of past programmes is '
                        'not wired up yet.',
                      ),
                    )),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The time ruler. Scrolls in lockstep with the rows below.
  Widget _buildRuler() {
    final fmt = DateFormat.Hm();
    final slots = (_hoursTotal * 60) ~/ _slotMinutes;

    return Container(
      height: 34,
      color: AppColors.background,
      child: Row(
        children: [
          const SizedBox(width: _channelColumnWidth),
          Expanded(
            child: SingleChildScrollView(
              controller: _timelineController,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: _timelineWidth,
                child: Stack(
                  children: [
                    for (var i = 0; i < slots; i++)
                      Positioned(
                        left: i * _slotWidth,
                        top: 0,
                        bottom: 0,
                        child: SizedBox(
                          width: _slotWidth,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(left: Insets.sm),
                              child: Text(
                                fmt.format(_origin.add(
                                    Duration(minutes: i * _slotMinutes))),
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<LiveChannel> channels) {
    final nowOffset = _offsetFor(_now);

    return NotificationListener<ScrollNotification>(
      // The rows own the horizontal gesture; the ruler mirrors them.
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.horizontal &&
            _timelineController.hasClients) {
          _timelineController.jumpTo(notification.metrics.pixels);
        }
        return false;
      },
      child: Stack(
        children: [
          SingleChildScrollView(
            controller: _rowsController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _channelColumnWidth + _timelineWidth,
              child: ListView.builder(
                // Lazy: only visible rows are built (spec §45).
                itemCount: channels.length,
                itemExtent: _rowHeight,
                itemBuilder: (context, i) {
                  final channel = channels[i];
                  return _GuideRow(
                    channel: channel,
                    selected: channel.streamId == _current?.streamId,
                    origin: _origin,
                    pxPerMinute: _pxPerMinute,
                    channelColumnWidth: _channelColumnWidth,
                    timelineWidth: _timelineWidth,
                    onTap: () => _play(channel),
                  );
                },
              ),
            ),
          ),

          // The "now" line, drawn over every row and tracking the shared
          // horizontal scroll.
          AnimatedBuilder(
            animation: _rowsController,
            builder: (context, _) {
              final scroll =
                  _rowsController.hasClients ? _rowsController.offset : 0.0;
              final x = _channelColumnWidth + nowOffset - scroll;
              if (x < _channelColumnWidth) return const SizedBox.shrink();
              return Positioned(
                left: x,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(width: 2, color: AppColors.accent),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CatchupPill extends StatelessWidget {
  const _CatchupPill({required this.days, required this.onTap});

  final int days;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        focusColor: AppColors.accentSoft,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg, vertical: Insets.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: AppColors.divider),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_rounded, color: Colors.white, size: 18),
              SizedBox(width: Insets.sm),
              Text('Catch-up',
                  style: TextStyle(color: Colors.white, fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One channel: fixed-width identity column, then its programme strip.
class _GuideRow extends ConsumerStatefulWidget {
  const _GuideRow({
    required this.channel,
    required this.selected,
    required this.origin,
    required this.pxPerMinute,
    required this.channelColumnWidth,
    required this.timelineWidth,
    required this.onTap,
  });

  final LiveChannel channel;
  final bool selected;
  final DateTime origin;
  final double pxPerMinute;
  final double channelColumnWidth;
  final double timelineWidth;
  final VoidCallback onTap;

  @override
  ConsumerState<_GuideRow> createState() => _GuideRowState();
}

class _GuideRowState extends ConsumerState<_GuideRow> {
  List<EpgProgramme> _programmes = const [];
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_requested || !mounted) return;
    _requested = true;
    final repo = ref.read(contentRepositoryProvider);
    if (repo == null) return;
    try {
      // Cached per channel in the repository, so scrolling back over a row
      // costs nothing.
      final list = await repo.fullGuide(widget.channel);
      if (!mounted) return;
      setState(() => _programmes = list);
    } catch (_) {
      // No guide is a normal state for many providers (AUDIT.md §7).
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Material(
      color: widget.selected
          ? AppColors.accent.withValues(alpha: 0.13)
          : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        focusColor: AppColors.accentSoft,
        child: Row(
          children: [
            // Left accent bar marks the channel currently playing.
            Container(
              width: 3,
              height: double.infinity,
              color: widget.selected ? AppColors.accent : Colors.transparent,
            ),
            SizedBox(
              width: widget.channelColumnWidth - 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm, vertical: Insets.sm),
                child: Row(
                  children: [
                    NetworkArtwork(
                      url: widget.channel.logo,
                      width: 46,
                      height: 36,
                      fit: BoxFit.contain,
                      fallbackIcon: Icons.live_tv_rounded,
                      fallbackLabel: widget.channel.name,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        widget.channel.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textPrimary,
                          fontSize: 11.5,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: widget.timelineWidth,
              child: _ProgrammeStrip(
                programmes: _programmes,
                origin: widget.origin,
                pxPerMinute: widget.pxPerMinute,
                width: widget.timelineWidth,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The programme blocks for one channel, positioned by real times. An empty
/// strip (no guide data) still draws its slot grid, matching the reference.
class _ProgrammeStrip extends StatelessWidget {
  const _ProgrammeStrip({
    required this.programmes,
    required this.origin,
    required this.pxPerMinute,
    required this.width,
  });

  final List<EpgProgramme> programmes;
  final DateTime origin;
  final double pxPerMinute;
  final double width;

  @override
  Widget build(BuildContext context) {
    const slotMinutes = 30;
    final slotWidth = slotMinutes * pxPerMinute;
    final slots = (width / slotWidth).ceil();

    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 0.5),
        ),
      ),
      child: Stack(
        children: [
          // Slot separators.
          for (var i = 0; i <= slots; i++)
            Positioned(
              left: i * slotWidth,
              top: 0,
              bottom: 0,
              child: Container(width: 0.5, color: AppColors.divider),
            ),

          for (final p in programmes) ..._block(context, p, slotWidth),
        ],
      ),
    );
  }

  List<Widget> _block(
      BuildContext context, EpgProgramme p, double slotWidth) {
    final left = p.start.difference(origin).inMinutes * pxPerMinute;
    final blockWidth = p.duration.inMinutes * pxPerMinute;

    // Off the visible timeline entirely.
    if (left + blockWidth < 0 || left > width) return const [];

    final clampedLeft = left < 0 ? 0.0 : left;
    final clampedWidth =
        (left < 0 ? blockWidth + left : blockWidth).clamp(0.0, width - clampedLeft);
    if (clampedWidth < 2) return const [];

    return [
      Positioned(
        left: clampedLeft,
        top: 4,
        bottom: 4,
        width: clampedWidth,
        child: Container(
          margin: const EdgeInsets.only(right: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            p.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 11,
              height: 1.15,
            ),
          ),
        ),
      ),
    ];
  }
}

class _GuideSkeleton extends StatelessWidget {
  const _GuideSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 8,
      itemExtent: 68,
      itemBuilder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm, vertical: Insets.sm),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Container(height: 11, width: 74, color: AppColors.surface),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: Container(height: 40, color: AppColors.surface),
            ),
          ],
        ),
      ),
    );
  }
}
