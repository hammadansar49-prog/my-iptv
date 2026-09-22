import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../providers.dart';
import '../widgets/category_strip.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';

/// Movies grid with movie-only search (spec §14, §15).
class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
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
    final categoryId = ref.watch(selectedCategoryProvider(ContentSection.movies));

    return Scaffold(
      appBar: AppBar(title: const Text('Movies')),
      body: Column(
        children: [
          ScopedSearchField(
            controller: _searchController,
            hint: 'Search movies',
            onChanged: _onSearchChanged,
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
          if (_query.isEmpty)
            const CategoryStrip(section: ContentSection.movies),
          Expanded(child: _buildBody(categoryId)),
        ],
      ),
    );
  }

  Widget _buildBody(String categoryId) {
    if (_query.isNotEmpty) {
      // Movies ONLY — no channels, no series, no episodes.
      return FutureBuilder<List<Movie>>(
        future: ref.read(contentRepositoryProvider)?.searchMovies(_query),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const PosterGridSkeleton();
          }
          final results = snap.data ?? const <Movie>[];
          if (results.isEmpty) {
            return const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No Movies Found',
              message: 'Nothing matches that search in Movies.',
            );
          }
          return _grid(results);
        },
      );
    }

    final async = ref.watch(moviesProvider(categoryId));
    return async.when(
      loading: () => const PosterGridSkeleton(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: ErrorBanner(
          message: 'Could not load movies.',
          onRetry: () => ref.invalidate(moviesProvider(categoryId)),
        ),
      ),
      data: (movies) => movies.isEmpty
          ? const EmptyState(
              icon: Icons.movie_outlined,
              title: 'No Movies Found',
              message: 'This category is empty.',
            )
          : _grid(movies),
    );
  }

  Widget _grid(List<Movie> movies) {
    // A lazy grid: only visible posters are built and decoded (spec §14/§46).
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
          Insets.lg, Insets.md, Insets.lg, Insets.xxl * 3),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        childAspectRatio: 0.58,
        crossAxisSpacing: Insets.md,
        mainAxisSpacing: Insets.lg,
      ),
      itemCount: movies.length,
      itemBuilder: (context, i) => _MovieCard(movie: movies[i]),
    );
  }
}

class _MovieCard extends ConsumerWidget {
  const _MovieCard({required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          focusColor: AppColors.accentSoft,
          onTap: () => context.push(Routes.movieDetail, extra: movie),
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
