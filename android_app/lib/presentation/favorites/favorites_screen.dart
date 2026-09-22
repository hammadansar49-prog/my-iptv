import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';

/// Favorites grouped into Live TV / Movies / Series (spec §30). Local only —
/// the backend does not sync favorites (AUDIT.md §4).
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(favoritesProvider(null));

    if (all.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Favorites')),
        body: const EmptyState(
          icon: Icons.favorite_border_rounded,
          title: 'No Favorites Yet',
          message: 'Tap the heart on any channel, movie or series.',
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Favorites'),
          bottom: const TabBar(
            indicatorColor: AppColors.accent,
            labelColor: AppColors.accent,
            unselectedLabelColor: AppColors.textSecondary,
            tabs: [
              Tab(text: 'Live TV'),
              Tab(text: 'Movies'),
              Tab(text: 'Series'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _FavoriteList(section: ContentSection.live),
            _FavoriteList(section: ContentSection.movies),
            _FavoriteList(section: ContentSection.series),
          ],
        ),
      ),
    );
  }
}

class _FavoriteList extends ConsumerWidget {
  const _FavoriteList({required this.section});

  final ContentSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(favoritesProvider(section));

    if (items.isEmpty) {
      return EmptyState(
        icon: switch (section) {
          ContentSection.live => Icons.live_tv_outlined,
          ContentSection.movies => Icons.movie_outlined,
          ContentSection.series => Icons.video_library_outlined,
        },
        title: switch (section) {
          ContentSection.live => 'No Channels Found',
          ContentSection.movies => 'No Movies Found',
          ContentSection.series => 'No Series Found',
        },
        message: 'Nothing saved here yet.',
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
            child: Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Row(
                children: [
                  NetworkArtwork(
                    url: entry.thumb,
                    width: section == ContentSection.live ? 56 : 48,
                    height: section == ContentSection.live ? 42 : 68,
                    fit: section == ContentSection.live
                        ? BoxFit.contain
                        : BoxFit.cover,
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
                  IconButton(
                    tooltip: 'Remove',
                    onPressed: () => ref
                        .read(libraryRepositoryProvider)
                        .toggleFavorite(entry),
                    icon: const Icon(Icons.favorite_rounded, size: 20),
                    color: AppColors.accent,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
