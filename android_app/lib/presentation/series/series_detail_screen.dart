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
import '../widgets/download_button.dart';
import '../widgets/network_artwork.dart';

/// Series → seasons → episodes → player (spec §16). Same full-bleed-poster
/// layout as [MovieDetailScreen], since the reference uses the identical
/// hero treatment for both.
class SeriesDetailScreen extends ConsumerStatefulWidget {
  const SeriesDetailScreen({super.key, required this.series});

  final Series series;

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends ConsumerState<SeriesDetailScreen> {
  int? _season;

  PlaybackRequest _requestFor(Series series, Episode e) {
    final repo = ref.read(contentRepositoryProvider)!;
    return PlaybackRequest(
      url: repo.episodeUrl(e),
      title: series.name,
      subtitle: '${e.tag} · ${e.title}',
      isLive: false,
      historyKey: e.key,
      thumb: e.still ?? series.cover,
      section: ContentSection.series,
      replay: PlaybackRef(
        section: ContentSection.series,
        streamId: e.id,
        seriesId: series.seriesId,
        season: e.season,
        episodeId: e.id,
        ext: e.ext,
      ),
    );
  }

  /// The episode the top Play button should open: whichever episode has an
  /// in-progress history entry, or S01E01 otherwise. No invented "resume
  /// point" when nothing has actually been watched.
  Episode _startingEpisode(SeriesDetail detail) {
    final library = ref.read(libraryRepositoryProvider);
    for (final n in detail.seasonNumbers) {
      for (final e in detail.seasons[n] ?? const []) {
        final h = library.historyFor(e.key);
        if (h != null && h.isContinueWatching) return e;
      }
    }
    final first = detail.seasonNumbers.first;
    return detail.seasons[first]!.first;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final async = ref.watch(seriesDetailProvider(widget.series));
    final size = MediaQuery.sizeOf(context);

    ref.watch(libraryRevisionProvider);
    final isFavorite = ref
        .watch(favoritesProvider(ContentSection.series))
        .any((f) => f.key == widget.series.key);

    void toggleFavorite() =>
        ref.read(libraryRepositoryProvider).toggleFavorite(FavoriteEntry(
              key: widget.series.key,
              section: ContentSection.series,
              title: widget.series.name,
              refId: '${widget.series.seriesId}',
              thumb: widget.series.cover,
              addedAt: DateTime.now(),
            ));

    return Scaffold(
      backgroundColor: AppColors.background,
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
            return Stack(
              children: [
                const EmptyState(
                  icon: Icons.video_library_outlined,
                  title: 'No Episodes Found',
                  message: 'This series has no episodes from the provider.',
                ),
                _BackButton(onTap: () => Navigator.of(context).maybePop()),
              ],
            );
          }

          final seasons = detail.seasonNumbers;
          final season = _season ?? seasons.first;
          final episodes = detail.seasons[season] ?? const [];
          final start = _startingEpisode(detail);

          return Stack(
            children: [
              CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: size.height * 0.62,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NetworkArtwork(
                            url: detail.series.cover,
                            width: size.width,
                            height: size.height * 0.62,
                            borderRadius: BorderRadius.zero,
                            fallbackLabel: detail.series.name,
                          ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.center,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  AppColors.background
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Insets.lg, 0, Insets.lg, Insets.xxl),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(detail.series.name, style: text.headlineMedium),

                          if (detail.series.year != null ||
                              detail.series.rating != null) ...[
                            const SizedBox(height: Insets.sm),
                            Row(
                              children: [
                                if (detail.series.year != null)
                                  Text(detail.series.year!,
                                      style: text.bodyMedium),
                                if (detail.series.year != null &&
                                    detail.series.rating != null)
                                  const Text('  ·  ',
                                      style: TextStyle(
                                          color: AppColors.textTertiary)),
                                if (detail.series.rating != null) ...[
                                  const Icon(Icons.star_rounded,
                                      size: 15, color: AppColors.tileYellow),
                                  const SizedBox(width: 3),
                                  Text(
                                      detail.series.rating!
                                          .toStringAsFixed(1),
                                      style: text.bodyMedium),
                                ],
                              ],
                            ),
                          ],

                          if (detail.genre != null) ...[
                            const SizedBox(height: Insets.sm),
                            Text(
                              detail.genre!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium,
                            ),
                          ],

                          const SizedBox(height: Insets.lg),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () => context.push(
                                Routes.player,
                                extra: _requestFor(detail.series, start),
                              ),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('Play'),
                            ),
                          ),

                          if (detail.series.plot != null) ...[
                            const SizedBox(height: Insets.lg),
                            Text(detail.series.plot!, style: text.bodyLarge),
                          ],

                          if (detail.cast != null) ...[
                            const SizedBox(height: Insets.md),
                            Text('Cast', style: text.titleMedium),
                            const SizedBox(height: Insets.xs),
                            Text(detail.cast!, style: text.bodyMedium),
                          ],

                          const SizedBox(height: Insets.xl),
                          _Action(
                            icon: isFavorite
                                ? Icons.check_rounded
                                : Icons.add_rounded,
                            label: 'My List',
                            active: isFavorite,
                            onTap: toggleFavorite,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.lg, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text('Seasons', style: text.headlineSmall),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: Insets.md, vertical: Insets.sm),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(Radii.pill),
                            ),
                            child: Text(
                              '• Season $season • Episodes ${episodes.length}',
                              style: text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 56,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(
                            horizontal: Insets.lg, vertical: Insets.md),
                        scrollDirection: Axis.horizontal,
                        itemCount: seasons.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: Insets.sm),
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
                              color:
                                  selected ? Colors.white : AppColors.textPrimary,
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
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                        Insets.lg, Insets.sm, Insets.lg, Insets.xxl * 2),
                    sliver: SliverList.list(
                      children: episodes
                          .map((e) => _EpisodeRow(
                                episode: e,
                                series: detail.series,
                              ))
                          .toList(),
                    ),
                  ),
                ],
              ),
              _BackButton(onTap: () => Navigator.of(context).maybePop()),
            ],
          );
        },
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: Insets.lg,
      top: MediaQuery.paddingOf(context).top + Insets.sm,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          focusColor: Colors.white24,
          child: const SizedBox(
            width: 42,
            height: 42,
            child: Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      focusColor: AppColors.accentSoft,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm, vertical: Insets.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: Insets.sm),
            Text(label, style: TextStyle(color: color, fontSize: 14)),
          ],
        ),
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
                SizedBox(
                  width: 96,
                  height: 56,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetworkArtwork(
                        url: episode.still ?? series.cover,
                        width: 96,
                        height: 56,
                      ),
                      const Center(
                        child: Icon(Icons.play_circle_fill_rounded,
                            color: Colors.white70, size: 30),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Episode ${episode.episodeNumber}',
                          style: text.bodySmall),
                      const SizedBox(height: 2),
                      Text(
                        '${series.name} - ${episode.tag}'
                        '${episode.title.isEmpty ? '' : ' - ${episode.title}'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600),
                      ),
                      if (episode.durationSeconds != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _duration(episode.durationSeconds!),
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
                DownloadButton(
                  url: repo.episodeUrl(episode),
                  background: AppColors.surfaceHigh,
                  buildRequest: () => DownloadRequest(
                    url: repo.episodeUrl(episode),
                    title: series.name,
                    ext: episode.ext,
                    subtitle: episode.title,
                    seriesName: series.name,
                    seasonEpisodeTag: episode.tag,
                    thumb: episode.still ?? series.cover,
                    isEpisode: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _duration(int seconds) {
    final d = Duration(seconds: seconds);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
