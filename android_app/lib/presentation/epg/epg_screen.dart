import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/epg.dart';
import '../providers.dart';
import '../widgets/category_strip.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';

/// Programme guide.
///
/// The PC app has no EPG at all, so this is new work built on the standard
/// Xtream endpoints (AUDIT.md §7). Two design constraints drive the
/// implementation:
///
///  * spec §12 — each channel shows TWO rows of information (now and next),
///    not a flat list
///  * spec §45 — the dataset is large, so rows render lazily, the guide is
///    fetched per visible channel and cached, and the "now" progress is
///    computed from the local clock on a single shared 30s tick rather than
///    a timer per row
class EpgScreen extends ConsumerStatefulWidget {
  const EpgScreen({super.key});

  @override
  ConsumerState<EpgScreen> createState() => _EpgScreenState();
}

class _EpgScreenState extends ConsumerState<EpgScreen> {
  /// ONE timer for the whole screen. A timer per row is exactly the kind of
  /// thing that produced the previous app's CPU problem (spec §47).
  Timer? _clock;
  DateTime _now = DateTime.now();

  String _query = '';
  Timer? _debounce;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final categoryId = ref.watch(selectedCategoryProvider(ContentSection.live));

    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.lg, 0, Insets.lg, Insets.sm),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                // Spec §13: inside EPG, search means channels and programmes
                // only — never movies, series or episodes.
                hintText: 'Search channels and programmes',
                prefixIcon: const Icon(Icons.search_rounded,
                    color: AppColors.textSecondary, size: 20),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        color: AppColors.textSecondary,
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Insets.lg, vertical: Insets.md),
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_query.isEmpty)
            const CategoryStrip(section: ContentSection.live),
          Expanded(child: _buildBody(categoryId)),
        ],
      ),
    );
  }

  Widget _buildBody(String categoryId) {
    if (_query.isNotEmpty) {
      return FutureBuilder<List<LiveChannel>>(
        future: ref.read(contentRepositoryProvider)?.searchChannels(_query),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final results = snap.data ?? const <LiveChannel>[];
          if (results.isEmpty) {
            return const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No Channels Found',
              message: 'Nothing in the guide matches that search.',
            );
          }
          return _guideList(results);
        },
      );
    }

    final async = ref.watch(liveChannelsProvider(categoryId));
    return async.when(
      loading: () => const _GuideSkeleton(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: ErrorBanner(
          message: 'Could not load the guide.',
          onRetry: () => ref.invalidate(liveChannelsProvider(categoryId)),
        ),
      ),
      data: (channels) => channels.isEmpty
          ? const EmptyState(
              icon: Icons.grid_view_outlined,
              title: 'No Channels Found',
              message: 'This category is empty.',
            )
          : _guideList(channels),
    );
  }

  Widget _guideList(List<LiveChannel> channels) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: Insets.xxl * 3),
      itemCount: channels.length,
      // Fixed extent lets the viewport skip layout for off-screen rows.
      itemExtent: 92,
      itemBuilder: (context, i) => _GuideRow(
        channel: channels[i],
        now: _now,
      ),
    );
  }
}

/// The two-row layout from spec §12: channel identity on the left, then the
/// current programme with its progress, and the next programme beneath it.
class _GuideRow extends ConsumerStatefulWidget {
  const _GuideRow({required this.channel, required this.now});

  final LiveChannel channel;
  final DateTime now;

  @override
  ConsumerState<_GuideRow> createState() => _GuideRowState();
}

class _GuideRowState extends ConsumerState<_GuideRow> {
  ChannelGuide? _guide;
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
      final guide = await repo.guideFor(widget.channel);
      if (!mounted) return;
      setState(() => _guide = guide);
    } catch (_) {
      // "No guide data from this provider" is a normal outcome.
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final guide = _guide;
    final current = guide?.now;
    final next = guide?.next;
    final timeFmt = DateFormat.Hm();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        focusColor: AppColors.accentSoft,
        onTap: () {
          // Live playback always goes through the inline Live TV screen,
          // never straight into a standalone player (CLAUDE.md).
          context.push(Routes.liveTv, extra: widget.channel);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg, vertical: Insets.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              NetworkArtwork(
                url: widget.channel.logo,
                width: 56,
                height: 44,
                fit: BoxFit.contain,
                fallbackIcon: Icons.live_tv_rounded,
                fallbackLabel: widget.channel.name,
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 3),

                    // Row 1 — what is on now.
                    if (current != null) ...[
                      Row(
                        children: [
                          Text(
                            '${timeFmt.format(current.start)} - ${timeFmt.format(current.end)}',
                            style: text.bodySmall
                                ?.copyWith(color: AppColors.accent),
                          ),
                          const SizedBox(width: Insets.sm),
                          Expanded(
                            child: Text(
                              current.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(
                                  color: AppColors.textPrimary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: current.progressAt(widget.now),
                          minHeight: 2,
                          backgroundColor: AppColors.divider,
                          valueColor:
                              const AlwaysStoppedAnimation(AppColors.accent),
                        ),
                      ),
                      const SizedBox(height: 3),
                    ],

                    // Row 2 — what is on next.
                    if (next != null)
                      Text(
                        'Next ${timeFmt.format(next.start)}  ${next.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      )
                    else if (current == null)
                      Text(
                        'Live broadcast — no programme guide data from this provider.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton rather than a blank screen (spec §41).
class _GuideSkeleton extends StatelessWidget {
  const _GuideSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      itemCount: 8,
      itemExtent: 92,
      itemBuilder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.sm),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
            ),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(height: 12, width: 140, color: AppColors.surface),
                  const SizedBox(height: Insets.sm),
                  Container(height: 10, width: 220, color: AppColors.surface),
                  const SizedBox(height: Insets.xs),
                  Container(height: 10, width: 180, color: AppColors.surface),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
