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
import '../home/home_feed.dart';
import '../providers.dart';
import '../widgets/download_button.dart';
import '../widgets/favorite_heart_button.dart';
import '../widgets/network_artwork.dart';

/// Movie details: full-bleed poster, then a dark panel with the title,
/// genres, a Play button, the synopsis and the action row (spec §14).
class MovieDetailScreen extends ConsumerWidget {
  const MovieDetailScreen({super.key, required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final detailAsync = ref.watch(movieDetailProvider(movie));
    final detail = detailAsync.valueOrNull;
    final shown = detail?.movie ?? movie;
    final size = MediaQuery.sizeOf(context);

    // "More movies" strip under the details — the same catalogue already
    // loaded for Home/Movies, just with this title itself left out.
    // Suggestions: the same category's newest real titles (ContentFilter
    // drops dated event recordings, wrestling shows, missing/recycled
    // posters), topped up from the newest titles overall. It used to be the
    // entire 69k catalogue in panel order, junk first.
    final index = ref.watch(movieIndexProvider).valueOrNull;
    final more = <Movie>[];
    if (index != null) {
      final seen = <String>{movie.key};
      void add(Iterable<Movie> from) {
        for (final m in from) {
          if (more.length >= _suggestions) return;
          if (seen.add(m.key)) more.add(m);
        }
      }

      for (final b in index.buckets) {
        if (b.category.id == movie.categoryId) add(b.items);
      }
      add(index.newest);
    }

    ref.watch(libraryRevisionProvider);
    final library = ref.read(libraryRepositoryProvider);
    final isFavorite = library.isFavorite(movie.key);
    final history = library.historyFor(movie.key);
    final canResume = history?.isContinueWatching ?? false;

    // Genres as " / " separated line, from whatever the panel actually
    // returned. No invented tags.
    final genres = (detail?.genre ?? '')
        .split(RegExp(r'[,/]'))
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .join(' / ');

    PlaybackRequest request() {
      final repo = ref.read(contentRepositoryProvider)!;
      return PlaybackRequest(
        url: repo.movieUrl(shown),
        title: shown.name,
        isLive: false,
        historyKey: movie.key,
        thumb: shown.poster,
        startAt: canResume ? history!.resumeAt : Duration.zero,
        section: ContentSection.movies,
        replay: PlaybackRef(
          section: ContentSection.movies,
          streamId: '${shown.streamId}',
          ext: shown.ext,
        ),
      );
    }

    void toggleFavorite() => library.toggleFavorite(FavoriteEntry(
          key: movie.key,
          section: ContentSection.movies,
          title: shown.name,
          refId: '${shown.streamId}',
          thumb: shown.poster,
          addedAt: DateTime.now(),
        ));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
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
                        url: shown.poster,
                        width: size.width,
                        height: size.height * 0.62,
                        borderRadius: BorderRadius.zero,
                        fallbackLabel: shown.name,
                      ),
                      // Fade into the panel below.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.center,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, AppColors.background],
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
                      Text(shown.name, style: text.headlineMedium),

                      // Year / rating, only when the panel gave them.
                      if (shown.year != null || shown.rating != null) ...[
                        const SizedBox(height: Insets.sm),
                        Row(
                          children: [
                            if (shown.year != null)
                              Text(shown.year!, style: text.bodyMedium),
                            if (shown.year != null && shown.rating != null)
                              const Text('  ·  ',
                                  style:
                                      TextStyle(color: AppColors.textTertiary)),
                            if (shown.rating != null) ...[
                              const Icon(Icons.star_rounded,
                                  size: 15, color: AppColors.tileYellow),
                              const SizedBox(width: 3),
                              Text(shown.rating!.toStringAsFixed(1),
                                  style: text.bodyMedium),
                            ],
                          ],
                        ),
                      ],

                      if (genres.isNotEmpty) ...[
                        const SizedBox(height: Insets.sm),
                        Text(
                          genres,
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
                          onPressed: () =>
                              context.push(Routes.player, extra: request()),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(canResume ? 'Resume' : 'Play'),
                        ),
                      ),

                      if (canResume) ...[
                        const SizedBox(height: Insets.md),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: history!.progress,
                            minHeight: 3,
                            backgroundColor: AppColors.divider,
                            valueColor:
                                const AlwaysStoppedAnimation(AppColors.accent),
                          ),
                        ),
                      ],

                      if (detail?.plot != null) ...[
                        const SizedBox(height: Insets.lg),
                        Text(detail!.plot!, style: text.bodyLarge),
                      ],

                      if (detail?.cast != null) ...[
                        const SizedBox(height: Insets.md),
                        Text('Cast', style: text.titleMedium),
                        const SizedBox(height: Insets.xs),
                        Text(detail!.cast!, style: text.bodyMedium),
                      ],

                      const SizedBox(height: Insets.xl),
                      Row(
                        children: [
                          // One favourite control, not two. The reference
                          // shows both a "+" and a heart; they would do the
                          // same thing here, so they are consolidated.
                          _Action(
                            icon: isFavorite
                                ? Icons.check_rounded
                                : Icons.add_rounded,
                            label: 'My List',
                            active: isFavorite,
                            onTap: toggleFavorite,
                          ),
                          const SizedBox(width: Insets.xl),
                          if (ref.watch(contentRepositoryProvider)
                              case final repo?)
                            DownloadButton(
                              url: repo.movieUrl(shown),
                              showLabel: true,
                              buildRequest: () => DownloadRequest(
                                url: repo.movieUrl(shown),
                                title: shown.name,
                                ext: shown.ext,
                                thumb: shown.poster,
                              ),
                            ),
                          // Trailer: `get_vod_info` exposes `youtube_trailer`
                          // on some panels only, so the button appears only
                          // when there is actually a trailer to play.
                          if (detail?.trailer != null &&
                              detail!.trailer!.isNotEmpty) ...[
                            const SizedBox(width: Insets.xl),
                            _Action(
                              icon: Icons.smart_display_outlined,
                              label: 'Trailer',
                              onTap: () => ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(SnackBar(
                                  content: Text(
                                      'Trailer: ${detail.trailer}'),
                                )),
                            ),
                          ],
                        ],
                      ),

                      if (detailAsync.isLoading) ...[
                        const SizedBox(height: Insets.xl),
                        const Center(child: CircularProgressIndicator()),
                      ],

                      if (more.isNotEmpty) ...[
                        const SizedBox(height: Insets.xl),
                        Text('More Movies', style: text.titleMedium),
                      ],
                    ],
                  ),
                ),
              ),
              if (more.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                      Insets.lg, Insets.md, Insets.lg, Insets.xxl * 3),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      childAspectRatio: 0.58,
                      crossAxisSpacing: Insets.md,
                      mainAxisSpacing: Insets.lg,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _MoreMovieCard(movie: more[i]),
                      childCount: more.length,
                    ),
                  ),
                ),
            ],
          ),

          // Floating back button over the poster.
          Positioned(
            left: Insets.lg,
            top: MediaQuery.paddingOf(context).top + Insets.sm,
            child: Material(
              color: Colors.black.withValues(alpha: 0.45),
              shape: const CircleBorder(),
              child: InkWell(
                onTap: () => context.canPop()
                    ? context.pop()
                    : context.go(Routes.home),
                customBorder: const CircleBorder(),
                focusColor: Colors.white24,
                child: const SizedBox(
                  width: 42,
                  height: 42,
                  child: Icon(Icons.arrow_back_rounded, color: Colors.white),
                ),
              ),
            ),
          ),
          FavoriteHeartButton(
            isFavorite: isFavorite,
            title: shown.name,
            onToggle: toggleFavorite,
          ),
        ],
      ),
    );
  }
}

/// One poster in the "More Movies" grid at the bottom — tapping replaces
/// this detail screen with the new one rather than pushing on top, so the
/// back stack does not grow one entry per movie browsed this way.
class _MoreMovieCard extends StatelessWidget {
  const _MoreMovieCard({required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          focusColor: AppColors.accentSoft,
          onTap: () =>
              context.pushReplacement(Routes.movieDetail, extra: movie),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NetworkArtwork(
                url: movie.poster,
                width: width,
                height: width * 1.45,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                movie.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(color: AppColors.textPrimary),
              ),
              if (movie.year != null)
                Text(movie.year!, style: text.bodySmall),
            ],
          ),
        );
      },
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 26),
            const SizedBox(height: Insets.xs),
            Text(label,
                style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// How many titles the "More Movies" grid suggests.
const _suggestions = 30;
