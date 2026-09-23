import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';

/// "My List" — everything saved with the "+ My List" button (and the heart),
/// grouped into Movies / Series / Live TV. Reached from Profile → My Lists
/// and from the heart on Home. Local only; the backend does not sync lists
/// (AUDIT.md §4).
///
/// Every entry opens: a movie or series goes to its detail page, a channel
/// starts playing on Live TV.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(favoritesProvider(null));

    if (all.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('My List')),
        body: const EmptyState(
          icon: Icons.bookmark_border_rounded,
          title: 'Your List Is Empty',
          message: 'Tap "+ My List" on any movie or series (or the heart on a '
              'channel) to keep it here for later.',
        ),
      );
    }

    int count(ContentSection s) => all.where((e) => e.section == s).length;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My List'),
          bottom: TabBar(
            indicatorColor: AppColors.accent,
            labelColor: AppColors.accent,
            unselectedLabelColor: AppColors.textSecondary,
            tabs: [
              Tab(text: 'Movies (${count(ContentSection.movies)})'),
              Tab(text: 'Series (${count(ContentSection.series)})'),
              Tab(text: 'Live TV (${count(ContentSection.live)})'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _PosterGrid(section: ContentSection.movies),
            _PosterGrid(section: ContentSection.series),
            _ChannelList(),
          ],
        ),
      ),
    );
  }
}

/// Resolve a saved entry back to the real catalogue item and open it. The
/// catalogue is loaded up front by the loading screen, so this is a lookup.
void _open(BuildContext context, WidgetRef ref, FavoriteEntry entry) {
  void missing() => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
      content: Text('This title is no longer available from your provider.'),
    ));

  switch (entry.section) {
    case ContentSection.movies:
      final list = ref.read(moviesProvider('')).valueOrNull ?? const [];
      final movie = list.where((m) => '${m.streamId}' == entry.refId).firstOrNull;
      movie == null ? missing() : context.push(Routes.movieDetail, extra: movie);
    case ContentSection.series:
      final list = ref.read(seriesProvider('')).valueOrNull ?? const [];
      final series = list.where((s) => '${s.seriesId}' == entry.refId).firstOrNull;
      series == null ? missing() : context.push(Routes.seriesDetail, extra: series);
    case ContentSection.live:
      final list = ref.read(liveChannelsProvider('')).valueOrNull ?? const [];
      final channel = list.where((c) => '${c.streamId}' == entry.refId).firstOrNull;
      channel == null ? missing() : context.push(Routes.liveTv, extra: channel);
  }
}

class _PosterGrid extends ConsumerWidget {
  const _PosterGrid({required this.section});

  final ContentSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the catalogue lists alive so _open can resolve entries.
    ref.watch(section == ContentSection.movies
        ? moviesProvider('')
        : seriesProvider(''));
    final items = ref.watch(favoritesProvider(section));

    if (items.isEmpty) {
      return EmptyState(
        icon: section == ContentSection.movies
            ? Icons.movie_outlined
            : Icons.video_library_outlined,
        title: section == ContentSection.movies
            ? 'No Movies Saved'
            : 'No Series Saved',
        message: 'Tap "+ My List" on a poster to save it here.',
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
          Insets.lg, Insets.lg, Insets.lg, Insets.xxl * 3),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: Insets.lg,
        crossAxisSpacing: Insets.md,
        childAspectRatio: 0.52,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final entry = items[i];
        return LayoutBuilder(
          builder: (context, box) => InkWell(
            onTap: () => _open(context, ref, entry),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    NetworkArtwork(
                      url: entry.thumb,
                      width: box.maxWidth,
                      height: box.maxWidth * 1.5,
                      borderRadius: BorderRadius.circular(Radii.sm),
                      fallbackLabel: entry.title,
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _RemoveButton(entry: entry),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChannelList extends ConsumerWidget {
  const _ChannelList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(liveChannelsProvider(''));
    final items = ref.watch(favoritesProvider(ContentSection.live));

    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.live_tv_outlined,
        title: 'No Channels Saved',
        message: 'Tap the heart on a channel to save it here.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          Insets.lg, Insets.md, Insets.lg, Insets.xxl * 3),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final entry = items[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: Insets.md),
          child: Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              onTap: () => _open(context, ref, entry),
              borderRadius: BorderRadius.circular(Radii.md),
              child: Padding(
                padding: const EdgeInsets.all(Insets.md),
                child: Row(
                  children: [
                    NetworkArtwork(
                      url: entry.thumb,
                      width: 56,
                      height: 42,
                      fit: BoxFit.contain,
                      fallbackIcon: Icons.live_tv_rounded,
                      fallbackLabel: entry.title,
                    ),
                    const SizedBox(width: Insets.md),
                    Expanded(
                      child: Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    const Icon(Icons.play_circle_fill_rounded,
                        color: AppColors.accent, size: 26),
                    _RemoveButton(entry: entry, compact: false),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RemoveButton extends ConsumerWidget {
  const _RemoveButton({required this.entry, this.compact = true});

  final FavoriteEntry entry;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void remove() {
      ref.read(libraryRepositoryProvider).toggleFavorite(entry);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Removed "${entry.title}" from My List'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                ref.read(libraryRepositoryProvider).toggleFavorite(entry),
          ),
        ));
    }

    if (!compact) {
      return IconButton(
        tooltip: 'Remove from My List',
        onPressed: remove,
        icon: const Icon(Icons.close_rounded,
            size: 20, color: AppColors.textSecondary),
      );
    }
    return Semantics(
      button: true,
      label: 'Remove from My List',
      child: Material(
        color: Colors.black.withValues(alpha: 0.6),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: remove,
          child: const SizedBox.square(
            dimension: 28,
            child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
