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

/// Series grid with series-only search (spec §16, §17).
class SeriesScreen extends ConsumerStatefulWidget {
  const SeriesScreen({super.key});

  @override
  ConsumerState<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends ConsumerState<SeriesScreen> {
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
    final categoryId = ref.watch(selectedCategoryProvider(ContentSection.series));

    return Scaffold(
      appBar: AppBar(title: const Text('Series')),
      body: Column(
        children: [
          ScopedSearchField(
            controller: _searchController,
            hint: 'Search series',
            onChanged: _onSearchChanged,
            onClear: () {
              _searchController.clear();
              setState(() => _query = '');
            },
          ),
          if (_query.isEmpty)
            const CategoryStrip(section: ContentSection.series),
          Expanded(child: _buildBody(categoryId)),
        ],
      ),
    );
  }

  Widget _buildBody(String categoryId) {
    if (_query.isNotEmpty) {
      // Series ONLY — never movies or live results.
      return FutureBuilder<List<Series>>(
        future: ref.read(contentRepositoryProvider)?.searchSeries(_query),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const PosterGridSkeleton();
          }
          final results = snap.data ?? const <Series>[];
          if (results.isEmpty) {
            return const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No Series Found',
              message: 'Nothing matches that search in Series.',
            );
          }
          return _grid(results);
        },
      );
    }

    final async = ref.watch(seriesProvider(categoryId));
    return async.when(
      loading: () => const PosterGridSkeleton(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: ErrorBanner(
          message: 'Could not load series.',
          onRetry: () => ref.invalidate(seriesProvider(categoryId)),
        ),
      ),
      data: (list) => list.isEmpty
          ? const EmptyState(
              icon: Icons.video_library_outlined,
              title: 'No Series Found',
              message: 'This category is empty.',
            )
          : _grid(list),
    );
  }

  Widget _grid(List<Series> list) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
          Insets.lg, Insets.md, Insets.lg, Insets.xxl * 3),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        childAspectRatio: 0.58,
        crossAxisSpacing: Insets.md,
        mainAxisSpacing: Insets.lg,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _SeriesCard(series: list[i]),
    );
  }
}

class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.series});

  final Series series;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          focusColor: AppColors.accentSoft,
          onTap: () => context.push(Routes.seriesDetail, extra: series),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NetworkArtwork(
                url: series.cover,
                width: width,
                height: width * 1.45,
                fallbackIcon: Icons.video_library_outlined,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                series.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(color: AppColors.textPrimary),
              ),
              if (series.year != null)
                Text(series.year!, style: text.bodySmall),
            ],
          ),
        );
      },
    );
  }
}
