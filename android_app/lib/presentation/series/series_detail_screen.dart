import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../../services/download/download_manager.dart';
import '../../services/player/playback_request.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';

/// Series → seasons → episodes → player (spec §16).
class SeriesDetailScreen extends ConsumerStatefulWidget {
  const SeriesDetailScreen({super.key, required this.series});

  final Series series;

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends ConsumerState<SeriesDetailScreen> {
  int? _season;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final async = ref.watch(seriesDetailProvider(widget.series));

    final isFavorite = ref
        .watch(favoritesProvider(ContentSection.series))
        .any((f) => f.key == widget.series.key);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.series.name, maxLines: 1),
        actions: [
          IconButton(
            onPressed: () =>
                ref.read(libraryRepositoryProvider).toggleFavorite(
                      FavoriteEntry(
                        key: widget.series.key,
                        section: ContentSection.series,
                        title: widget.series.name,
                        refId: '${widget.series.seriesId}',
                        thumb: widget.series.cover,
                        addedAt: DateTime.now(),
                      ),
                    ),
            icon: Icon(
              isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: isFavorite ? AppColors.accent : AppColors.textPrimary,
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: ErrorBanner(
            message: 'Could not load this series.',
            onRetry: () =>
                ref.invalidate(seriesDetailProvider(widget.series)),
          ),
        ),
        data: (detail) {
          if (detail == null || detail.seasons.isEmpty) {
            return const EmptyState(
              icon: Icons.video_library_outlined,
              title: 'No Episodes Found',
              message: 'This series has no episodes from the provider.',
            );
          }

          final seasons = detail.seasonNumbers;
          final season = _season ?? seasons.first;
          final episodes = detail.seasons[season] ?? const [];

          return ListView(
            padding: const EdgeInsets.fromLTRB(
                Insets.lg, 0, Insets.lg, Insets.xxl * 2),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NetworkArtwork(
                    url: detail.series.cover,
                    width: 110,
                    height: 160,
                    fallbackIcon: Icons.video_library_outlined,
                  ),
                  const SizedBox(width: Insets.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(detail.series.name, style: text.titleLarge),
                        const SizedBox(height: Insets.xs),
                        Text(
                          '${seasons.length} season${seasons.length == 1 ? '' : 's'} · '
                          '${detail.episodeCount} episodes',
                          style: text.bodyMedium,
                        ),
                        if (detail.genre != null) ...[
                          const SizedBox(height: Insets.xs),
                          Text(detail.genre!, style: text.bodySmall),
                        ],
                      ],
                    ),
                  ),
                ],
              ),

              if (detail.series.plot != null) ...[
                const SizedBox(height: Insets.lg),
                Text(detail.series.plot!, style: text.bodyLarge),
              ],

              const SizedBox(height: Insets.xl),
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: seasons.length,
                  separatorBuilder: (_, __) => const SizedBox(width: Insets.sm),
                  itemBuilder: (context, i) {
                    final n = seasons[i];
                    final selected = n == season;
                    return ChoiceChip(
                      label: Text('Season $n'),
                      selected: selected,
                      showCheckmark: false,
                      backgroundColor: AppColors.surface,
                      selectedColor: AppColors.accent,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : AppColors.textPrimary,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      onSelected: (_) => setState(() => _season = n),
                    );
                  },
                ),
              ),

              const SizedBox(height: Insets.lg),
              ...episodes.map((e) => _EpisodeRow(
                    episode: e,
                    series: detail.series,
                  )),
            ],
          );
        },
      ),
    );
  }
}

class _EpisodeRow extends ConsumerWidget {
  const _EpisodeRow({required this.episode, required this.series});

  final Episode episode;
  final Series series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final repo = ref.watch(contentRepositoryProvider);
    if (repo == null) return const SizedBox.shrink();

    ref.watch(libraryRevisionProvider);
    final history = ref.read(libraryRepositoryProvider).historyFor(episode.key);

    final request = PlaybackRequest(
      url: repo.episodeUrl(episode),
      title: series.name,
      subtitle: '${episode.tag} · ${episode.title}',
      isLive: false,
      historyKey: episode.key,
      thumb: episode.still ?? series.cover,
      section: ContentSection.series,
      replay: PlaybackRef(
        section: ContentSection.series,
        streamId: episode.id,
        seriesId: series.seriesId,
        season: episode.season,
        episodeId: episode.id,
        ext: episode.ext,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          focusColor: AppColors.accentSoft,
          onTap: () => context.push(Routes.player, extra: request),
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Row(
              children: [
                NetworkArtwork(
                  url: episode.still ?? series.cover,
                  width: 96,
                  height: 56,
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${episode.episodeNumber}. ${episode.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge,
                      ),
                      if (episode.durationSeconds != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${(episode.durationSeconds! / 60).round()} min',
                          style: text.bodySmall,
                        ),
                      ],
                      if (history != null && history.isContinueWatching) ...[
                        const SizedBox(height: Insets.xs),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: history.progress,
                            minHeight: 2,
                            backgroundColor: AppColors.divider,
                            valueColor:
                                const AlwaysStoppedAnimation(AppColors.accent),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Download',
                  onPressed: () {
                    ref.read(downloadManagerProvider).add(DownloadRequest(
                          url: repo.episodeUrl(episode),
                          title: series.name,
                          ext: episode.ext,
                          subtitle: episode.title,
                          seriesName: series.name,
                          seasonEpisodeTag: episode.tag,
                          thumb: episode.still ?? series.cover,
                          isEpisode: true,
                        ));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Added to downloads')),
                    );
                  },
                  icon: const Icon(Icons.download_rounded, size: 20),
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
