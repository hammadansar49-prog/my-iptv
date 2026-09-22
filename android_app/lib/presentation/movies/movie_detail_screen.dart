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
import '../widgets/network_artwork.dart';

/// Movie details: artwork, metadata, and the Play / Resume / Favorite /
/// Download actions (spec §14).
class MovieDetailScreen extends ConsumerWidget {
  const MovieDetailScreen({super.key, required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final detailAsync = ref.watch(movieDetailProvider(movie));
    final detail = detailAsync.valueOrNull;
    final shown = detail?.movie ?? movie;

    final history =
        ref.watch(libraryRevisionProvider).whenOrNull(data: (_) => true) != null
            ? ref.read(libraryRepositoryProvider).historyFor(movie.key)
            : ref.read(libraryRepositoryProvider).historyFor(movie.key);
    final canResume = history?.isContinueWatching ?? false;

    final isFavorite = ref
        .watch(favoritesProvider(ContentSection.movies))
        .any((f) => f.key == movie.key);

    final downloads = ref.watch(downloadListProvider);
    final existing = downloads.where((d) => d.title == shown.name).toList();

    PlaybackRequest request({Duration startAt = Duration.zero}) {
      final repo = ref.read(contentRepositoryProvider)!;
      return PlaybackRequest(
        url: repo.movieUrl(shown),
        title: shown.name,
        isLive: false,
        historyKey: movie.key,
        thumb: shown.poster,
        startAt: startAt,
        section: ContentSection.movies,
        replay: PlaybackRef(
          section: ContentSection.movies,
          streamId: '${shown.streamId}',
          ext: shown.ext,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(shown.name, maxLines: 1)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            Insets.lg, 0, Insets.lg, Insets.xxl * 2),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NetworkArtwork(
                url: shown.poster,
                width: 120,
                height: 174,
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(shown.name, style: text.titleLarge),
                    const SizedBox(height: Insets.sm),
                    Wrap(
                      spacing: Insets.sm,
                      runSpacing: Insets.xs,
                      children: [
                        if (shown.year != null) _Chip(label: shown.year!),
                        if (shown.rating != null)
                          _Chip(
                            label: shown.rating!.toStringAsFixed(1),
                            icon: Icons.star_rounded,
                          ),
                        if (detail?.genre != null) _Chip(label: detail!.genre!),
                      ],
                    ),
                    if (detail?.durationSeconds != null) ...[
                      const SizedBox(height: Insets.sm),
                      Text(
                        _duration(detail!.durationSeconds!),
                        style: text.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: Insets.xl),

          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => context.push(
                    Routes.player,
                    extra: request(
                      startAt: canResume ? history!.resumeAt : Duration.zero,
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(canResume ? 'Resume' : 'Play'),
                ),
              ),
              const SizedBox(width: Insets.md),
              _IconAction(
                icon: isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: isFavorite ? AppColors.accent : AppColors.textPrimary,
                onTap: () =>
                    ref.read(libraryRepositoryProvider).toggleFavorite(
                          FavoriteEntry(
                            key: movie.key,
                            section: ContentSection.movies,
                            title: shown.name,
                            refId: '${shown.streamId}',
                            thumb: shown.poster,
                            addedAt: DateTime.now(),
                          ),
                        ),
              ),
              const SizedBox(width: Insets.sm),
              _IconAction(
                icon: existing.isEmpty
                    ? Icons.download_rounded
                    : Icons.download_done_rounded,
                color: existing.isEmpty
                    ? AppColors.textPrimary
                    : AppColors.success,
                onTap: () {
                  final repo = ref.read(contentRepositoryProvider);
                  if (repo == null) return;
                  ref.read(downloadManagerProvider).add(DownloadRequest(
                        url: repo.movieUrl(shown),
                        title: shown.name,
                        ext: shown.ext,
                        thumb: shown.poster,
                      ));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Added to downloads')),
                  );
                },
              ),
            ],
          ),

          if (canResume) ...[
            const SizedBox(height: Insets.md),
            LinearProgressIndicator(
              value: history!.progress,
              minHeight: 3,
              backgroundColor: AppColors.divider,
              valueColor: const AlwaysStoppedAnimation(AppColors.accent),
            ),
          ],

          if (detail?.plot != null) ...[
            const SizedBox(height: Insets.xl),
            Text('Overview', style: text.titleMedium),
            const SizedBox(height: Insets.sm),
            Text(detail!.plot!, style: text.bodyLarge),
          ],

          if (detail?.cast != null) ...[
            const SizedBox(height: Insets.lg),
            Text('Cast', style: text.titleMedium),
            const SizedBox(height: Insets.xs),
            Text(detail!.cast!, style: text.bodyMedium),
          ],

          if (detailAsync.isLoading) ...[
            const SizedBox(height: Insets.xl),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }

  static String _duration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.md, vertical: Insets.xs),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: AppColors.tileYellow),
            const SizedBox(width: 4),
          ],
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.onTap,
    required this.color,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        focusColor: AppColors.accentSoft,
        child: SizedBox(
          width: 50,
          height: 50,
          child: Icon(icon, color: color),
        ),
      ),
    );
  }
}
