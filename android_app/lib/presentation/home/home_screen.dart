
import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../auth/auth_controller.dart';
import '../providers.dart';
import '../widgets/network_artwork.dart';

/// Which kind of content the home feed is showing.
enum HomeFilter { all, movies, series, liveTv, ott }

extension on HomeFilter {
  String get label => switch (this) {
        HomeFilter.all => 'All',
        HomeFilter.movies => 'Movies',
        HomeFilter.series => 'Series',
        HomeFilter.liveTv => 'Live TV',
        HomeFilter.ott => 'OTT',
      };
}

/// Home: branding, search, type filters, and a featured carousel drawn from
/// the real catalogue (spec §9). Nothing here is placeholder content — if a
/// section has no data yet it says so rather than inventing entries.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  final _pageController = PageController(viewportFraction: 0.92);
  HomeFilter _filter = HomeFilter.all;
  int _page = 0;
  int _itemCount = 0;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    // Posters advance on their own — the reference carousel never sits
    // still — but a manual swipe (onPageChanged) still moves `_page`, so
    // this just keeps nudging forward from wherever the user left it.
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_pageController.hasClients || _itemCount <= 1) return;
      _pageController.animateToPage(
        (_page + 1) % _itemCount,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _searchController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// Record the catalogue size for the Accounts screen's STREAMS stat. Only
  /// runs once all three counts are actually known, so the number shown
  /// there is always real.
  void _recordStreamCount(int? movies, int? series, int? channels) {
    if (movies == null || series == null || channels == null) return;
    final accountId = ref.read(authControllerProvider).account?.id;
    if (accountId == null) return;
    final total = movies + series + channels;
    ref.read(accountSummaryStoreProvider).record(
          accountId,
          (existing) => existing.copyWith(
            username: ref.read(sessionProvider)?.userInfo.username,
            status: ref.read(sessionProvider)?.userInfo.status,
            expiresAt: ref.read(sessionProvider)?.userInfo.expiresAt,
            streamCount: total,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final moviesAsync = ref.watch(moviesProvider(''));
    final seriesAsync = ref.watch(seriesProvider(''));
    final channelsAsync = ref.watch(liveChannelsProvider(''));

    // Opportunistic, cheap, and only when everything is loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recordStreamCount(
        moviesAsync.valueOrNull?.length,
        seriesAsync.valueOrNull?.length,
        channelsAsync.valueOrNull?.length,
      );
    });

    final featured = _featured(
      moviesAsync.valueOrNull ?? const [],
      seriesAsync.valueOrNull ?? const [],
      channelsAsync.valueOrNull ?? const [],
    );
    // Scoped to what the active filter actually shows — Movies/Series/Live
    // are three independent fetches (movies alone can be tens of MB and
    // take several seconds), and there is no reason a Movies tab that is
    // already back should keep spinning just because Series or Live hasn't
    // answered yet. "All" mixes movies+series (see _featured below) but
    // never channels, so it does not wait on Live either.
    final isLoading = switch (_filter) {
      HomeFilter.movies || HomeFilter.ott => moviesAsync.isLoading,
      HomeFilter.series => seriesAsync.isLoading,
      HomeFilter.liveTv => channelsAsync.isLoading,
      HomeFilter.all => moviesAsync.isLoading || seriesAsync.isLoading,
    };
    _itemCount = featured.length;
    final backdropUrl = featured.isEmpty
        ? null
        : featured[_page.clamp(0, featured.length - 1)].artwork;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Positioned.fill(child: _Backdrop(url: backdropUrl)),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.lg, Insets.sm, Insets.lg, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('TheOttDeals', style: text.headlineSmall),
                  ),
                  Material(
                    color: AppColors.surface,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: () => context.push(Routes.favorites),
                      customBorder: const CircleBorder(),
                      focusColor: AppColors.accentSoft,
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(Icons.favorite_rounded,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.md),

            // Search. Tapping routes into the scoped search for whatever
            // filter is active — there is no uncontrolled global search
            // (spec §18).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              child: TextField(
                controller: _searchController,
                readOnly: true,
                onTap: _openScopedSearch,
                decoration: InputDecoration(
                  hintText: 'Search....',
                  prefixIcon: const Icon(Icons.search_rounded,
                      color: AppColors.textSecondary, size: 22),
                  suffixIcon: IconButton(
                    // Voice search is not implemented; saying so is better
                    // than a button that silently does nothing.
                    onPressed: () => ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(const SnackBar(
                        content: Text('Voice search is not available yet.'),
                      )),
                    icon: const Icon(Icons.mic_none_rounded,
                        color: AppColors.textSecondary, size: 22),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    borderSide: const BorderSide(color: AppColors.divider),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Insets.md),

            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                itemCount: HomeFilter.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: Insets.md),
                itemBuilder: (context, i) {
                  final f = HomeFilter.values[i];
                  return _FilterPill(
                    label: f.label,
                    selected: f == _filter,
                    onTap: () {
                      setState(() {
                        _filter = f;
                        _page = 0;
                      });
                      if (_pageController.hasClients) {
                        _pageController.jumpToPage(0);
                      }
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: Insets.lg),

            Expanded(
              child: _buildFeatured(featured, isLoading),
            ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openScopedSearch() {
    switch (_filter) {
      case HomeFilter.series:
        context.push(Routes.series);
      case HomeFilter.liveTv:
        context.push(Routes.liveTv);
      case HomeFilter.movies:
      case HomeFilter.all:
      case HomeFilter.ott:
        context.push(Routes.movies);
    }
  }

  /// The carousel's entries, from the real catalogue.
  ///
  /// "OTT" has no counterpart in the Xtream API — there is no such field in
  /// any response (AUDIT.md §2). Rather than invent one, the pill maps to
  /// the newest VOD additions, which is the closest honest reading.
  List<_FeaturedItem> _featured(
    List<Movie> movies,
    List<Series> series,
    List<LiveChannel> channels,
  ) {
    final out = <_FeaturedItem>[];

    void addMovies(List<Movie> source) {
      final sorted = [...source]..sort((a, b) {
          final x = a.addedAt, y = b.addedAt;
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return y.compareTo(x);
        });
      for (final m in sorted.take(10)) {
        out.add(_FeaturedItem(
          title: m.name,
          category: [if (m.year != null) m.year!, 'Movie'].join(' / '),
          artwork: m.poster,
          movie: m,
        ));
      }
    }

    switch (_filter) {
      case HomeFilter.movies:
        addMovies(movies);
      case HomeFilter.series:
        for (final s in series.take(10)) {
          out.add(_FeaturedItem(
            title: s.name,
            category: [if (s.year != null) s.year!, 'Series'].join(' / '),
            artwork: s.cover,
            series: s,
          ));
        }
      case HomeFilter.liveTv:
        for (final c in channels.take(10)) {
          out.add(_FeaturedItem(
            title: c.name,
            category: 'Live TV',
            artwork: c.logo,
            channel: c,
          ));
        }
      case HomeFilter.ott:
        addMovies(movies);
      case HomeFilter.all:
        addMovies(movies.take(5).toList());
        for (final s in series.take(5)) {
          out.add(_FeaturedItem(
            title: s.name,
            category: [if (s.year != null) s.year!, 'Series'].join(' / '),
            artwork: s.cover,
            series: s,
          ));
        }
    }
    return out;
  }

  Widget _buildFeatured(List<_FeaturedItem> items, bool isLoading) {
    if (items.isEmpty) {
      return Center(
        child: isLoading
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Text(
                  'Nothing to show here yet.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: _FeaturedCard(item: items[i]),
            ),
          ),
        ),
        const SizedBox(height: Insets.md),
        // Dots. Capped so a 10-item carousel does not draw a scrollbar of
        // specks the way the reference does.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < items.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _page ? 18 : 5,
                height: 5,
                decoration: BoxDecoration(
                  color: i == _page ? Colors.white : AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
        const SizedBox(height: Insets.xxl * 2.2),
      ],
    );
  }
}

/// The soft, blurred wash behind the whole Home screen (reference: the
/// current poster, blown up and blurred, darkened so the search/filter row
/// stays readable over any artwork). Crossfades when the carousel advances
/// rather than snapping, since a hard cut behind translucent chrome reads as
/// a glitch.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: AppColors.background,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: url == null
                ? const SizedBox.shrink(key: ValueKey('none'))
                : ImageFiltered(
                    key: ValueKey(url),
                    imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Image.network(
                      url!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(color: Color(0xB3000000)),
        ),
      ],
    );
  }
}

class _FeaturedItem {
  const _FeaturedItem({
    required this.title,
    required this.category,
    required this.artwork,
    this.movie,
    this.series,
    this.channel,
  });

  final String title;
  final String category;
  final String? artwork;
  final Movie? movie;
  final Series? series;
  final LiveChannel? channel;
}

class _FeaturedCard extends ConsumerWidget {
  const _FeaturedCard({required this.item});

  final _FeaturedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;

    final favoriteKey = item.movie?.key ?? item.series?.key ?? item.channel?.key;
    ref.watch(libraryRevisionProvider);
    final isFavorite = favoriteKey != null &&
        ref.read(libraryRepositoryProvider).isFavorite(favoriteKey);

    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(Radii.lg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              NetworkArtwork(
                url: item.artwork,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                borderRadius: BorderRadius.zero,
                fit: item.channel != null ? BoxFit.contain : BoxFit.cover,
                fallbackLabel: item.title,
              ),

              // Gradient so the text stays legible over any artwork.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xE6000000)],
                  ),
                ),
              ),

              Positioned(
                left: Insets.lg,
                right: Insets.lg,
                bottom: Insets.lg,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: text.bodyLarge?.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: Insets.md),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: () => _play(context, ref),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Play'),
                          ),
                        ),
                        const SizedBox(width: Insets.md),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.16),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: favoriteKey == null
                                ? null
                                : () => _toggleFavorite(ref, favoriteKey),
                            icon: Icon(isFavorite
                                ? Icons.check_rounded
                                : Icons.add_rounded),
                            label: const Text('My List'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _play(BuildContext context, WidgetRef ref) {
    final movie = item.movie;
    final series = item.series;
    final channel = item.channel;

    if (series != null) {
      context.push(Routes.seriesDetail, extra: series);
      return;
    }
    if (channel != null) {
      // Live always goes through the inline screen (CLAUDE.md).
      context.push(Routes.liveTv, extra: channel);
      return;
    }
    if (movie != null) {
      context.push(Routes.movieDetail, extra: movie);
    }
  }

  void _toggleFavorite(WidgetRef ref, String key) {
    final section = item.movie != null
        ? ContentSection.movies
        : item.series != null
            ? ContentSection.series
            : ContentSection.live;
    final refId = item.movie != null
        ? '${item.movie!.streamId}'
        : item.series != null
            ? '${item.series!.seriesId}'
            : '${item.channel!.streamId}';

    ref.read(libraryRepositoryProvider).toggleFavorite(FavoriteEntry(
          key: key,
          section: section,
          title: item.title,
          refId: refId,
          thumb: item.artwork,
          addedAt: DateTime.now(),
        ));
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        focusColor: AppColors.accentSoft,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            border: selected
                ? null
                : Border.all(color: AppColors.divider, width: 1.2),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppColors.textPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}
