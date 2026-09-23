import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
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
import 'home_feed.dart';
import 'home_rows.dart';

extension on HomeFilter {
  String get label => switch (this) {
        HomeFilter.all => 'All',
        HomeFilter.movies => 'Movies',
        HomeFilter.series => 'Series',
        HomeFilter.liveTv => 'Live TV',
        HomeFilter.ott => 'OTT',
      };
}

/// Home: branding, search, type filters, Continue Watching, a featured
/// carousel and one row per category — all drawn from the real catalogue
/// (spec §9). Nothing here is placeholder content — if a section has no data
/// yet it says so rather than inventing entries.
///
/// One [CustomScrollView]: the title bar is pinned, everything else scrolls
/// under it, and every row below the carousel is built lazily.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  final _scroll = ScrollController();

  /// Scroll-driven header state. Notifiers rather than setState so a scroll
  /// frame rebuilds two small widgets, not the whole feed.
  final _scrolled = ValueNotifier<bool>(false);
  final _searchOffscreen = ValueNotifier<bool>(false);

  /// The carousel's current artwork, for the blurred backdrop. Kept here
  /// (not in the carousel) because the backdrop sits behind the whole list.
  final _backdropUrl = ValueNotifier<String?>(null);

  HomeFilter _filter = HomeFilter.all;
  bool _streamCountRecorded = false;

  /// Roughly the search field's height: past this it has slid under the
  /// pinned title bar, which then offers its own search button.
  static const _searchHiddenAfter = 48.0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchController.dispose();
    _scrolled.dispose();
    _searchOffscreen.dispose();
    _backdropUrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final offset = _scroll.offset;
    _scrolled.value = offset > 0.5;
    _searchOffscreen.value = offset > _searchHiddenAfter;
  }

  /// Record the catalogue size for the Accounts screen's STREAMS stat. Only
  /// runs once all three counts are actually known, so the number shown
  /// there is always real — and only once, since the store writes to disk.
  void _recordStreamCount(int? movies, int? series, int? channels) {
    if (_streamCountRecorded) return;
    if (movies == null || series == null || channels == null) return;
    final accountId = ref.read(authControllerProvider).account?.id;
    if (accountId == null) return;
    _streamCountRecorded = true;
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
    final movies = ref.watch(moviesProvider('')).valueOrNull?.length;
    final series = ref.watch(seriesProvider('')).valueOrNull?.length;
    final channels = ref.watch(liveChannelsProvider('')).valueOrNull?.length;

    // Opportunistic, cheap, and only when everything is loaded.
    if (!_streamCountRecorded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recordStreamCount(movies, series, channels);
      });
    }

    // The shell's Scaffold uses extendBody, which adds the floating nav
    // bar's height to this padding.
    final bottomClearance = MediaQuery.paddingOf(context).bottom + Insets.xl;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          _Backdrop(url: _backdropUrl, scroll: _scroll),
          CustomScrollView(
            controller: _scroll,
            // A little beyond the default so the next row's posters have
            // started decoding before it scrolls into view.
            cacheExtent: 400,
            slivers: [
              PinnedHeaderSliver(
                child: _TitleBar(
                  scrolled: _scrolled,
                  searchOffscreen: _searchOffscreen,
                  onSearch: _openScopedSearch,
                ),
              ),
              SliverToBoxAdapter(child: _buildSearchField()),
              SliverToBoxAdapter(child: _buildFilterPills()),
              // Above the carousel on purpose: Back from the player lands
              // here, and the thing just watched should be the first thing
              // seen.
              SliverToBoxAdapter(
                child: ContinueWatchingSection(filter: _filter),
              ),
              SliverToBoxAdapter(
                // Auto-advance repaints only the carousel, not the list.
                child: RepaintBoundary(
                  child: _FeaturedCarousel(
                    // A new filter starts a fresh carousel at page one.
                    key: ValueKey(_filter),
                    filter: _filter,
                    onArtwork: (url) => _backdropUrl.value = url,
                  ),
                ),
              ),
              HomeFeedSliver(filter: _filter),
              SliverToBoxAdapter(child: SizedBox(height: bottomClearance)),
            ],
          ),
        ],
      ),
    );
  }

  // Search. Tapping routes into the scoped search for whatever filter is
  // active — there is no uncontrolled global search (spec §18).
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.xs, Insets.lg, 0),
      child: TextField(
        controller: _searchController,
        readOnly: true,
        onTap: _openScopedSearch,
        decoration: InputDecoration(
          hintText: 'Search....',
          prefixIcon: const Icon(Icons.search_rounded,
              color: AppColors.textSecondary, size: 22),
          suffixIcon: IconButton(
            // Voice search is not implemented; saying so is better than a
            // button that silently does nothing.
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
    );
  }

  Widget _buildFilterPills() {
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.sm),
      child: SizedBox(
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
                if (f != _filter) setState(() => _filter = f);
              },
            );
          },
        ),
      ),
    );
  }

  void _openScopedSearch() {
    // Search covers the whole section, so it opens on "All" rather than on
    // whichever category a Home row last opened.
    final section = switch (_filter) {
      HomeFilter.series => ContentSection.series,
      HomeFilter.liveTv => ContentSection.live,
      HomeFilter.movies || HomeFilter.all || HomeFilter.ott =>
        ContentSection.movies,
    };
    ref.read(selectedCategoryProvider(section).notifier).state = '';
    switch (section) {
      case ContentSection.series:
        context.push(Routes.series);
      case ContentSection.live:
        context.push(Routes.liveTv);
      case ContentSection.movies:
        context.push(Routes.movies);
    }
  }
}

// ---- Pinned title bar ------------------------------------------------------

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.scrolled,
    required this.searchOffscreen,
    required this.onSearch,
  });

  final ValueListenable<bool> scrolled;
  final ValueListenable<bool> searchOffscreen;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final title = Theme.of(context)
        .textTheme
        .headlineSmall
        ?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0.3);

    return Stack(
      children: [
        // Frosted only once something is actually underneath: at rest the
        // backdrop shows through untouched, and a blur that is invisible
        // still costs a full pass every frame.
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: scrolled,
            builder: (context, on, child) => AnimatedOpacity(
              opacity: on ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: child,
            ),
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x99101012),
                    border: Border(
                      bottom: BorderSide(color: Color(0x14FFFFFF), width: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              Insets.lg, top + Insets.sm, Insets.lg, Insets.sm),
          child: Row(
            children: [
              Expanded(child: Text('MY IPTV', style: title)),
              ValueListenableBuilder<bool>(
                valueListenable: searchOffscreen,
                builder: (context, show, child) => ExcludeFocus(
                  excluding: !show,
                  child: IgnorePointer(
                    ignoring: !show,
                    child: ExcludeSemantics(
                      excluding: !show,
                      child: AnimatedOpacity(
                        opacity: show ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: child,
                      ),
                    ),
                  ),
                ),
                child: _CircleButton(
                  icon: Icons.search_rounded,
                  label: 'Search',
                  onTap: onSearch,
                ),
              ),
              const SizedBox(width: 10),
              _CircleButton(
                icon: Icons.favorite_rounded,
                label: 'Favorites',
                onTap: () => context.push(Routes.favorites),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          focusColor: AppColors.accentSoft,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

// ---- Carousel --------------------------------------------------------------

class _FeaturedCarousel extends ConsumerStatefulWidget {
  const _FeaturedCarousel({
    super.key,
    required this.filter,
    required this.onArtwork,
  });

  final HomeFilter filter;
  final ValueChanged<String?> onArtwork;

  @override
  ConsumerState<_FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends ConsumerState<_FeaturedCarousel> {
  final _pageController = PageController(viewportFraction: 0.92);
  int _page = 0;
  int _itemCount = 0;
  Timer? _autoTimer;
  ModalRoute<Object?>? _route;
  double _screenHeight = 0;

  bool _reported = false;
  String? _reportedUrl;

  @override
  void initState() {
    super.initState();
    // Posters advance on their own — the reference carousel never sits
    // still — but a manual swipe (onPageChanged) still moves `_page`, so
    // this just keeps nudging forward from wherever the user left it.
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) => _advance());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _advance() {
    if (!mounted || !_pageController.hasClients || _itemCount <= 1) return;
    // Nobody is looking: the player or a detail page is on top, or the
    // carousel has scrolled away. Animating then only burns frames (and
    // swaps the backdrop behind the user's back).
    if (_route != null && !_route!.isCurrent) return;
    if (!_isOnScreen()) return;
    _pageController.animateToPage(
      (_page + 1) % _itemCount,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
    );
  }

  bool _isOnScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    return top < _screenHeight && top + box.size.height > 0;
  }

  /// Tell Home which artwork to blur behind everything — after the frame,
  /// since the backdrop is a listener outside this subtree.
  void _report(String? url) {
    if (_reported && url == _reportedUrl) return;
    _reported = true;
    _reportedUrl = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onArtwork(url);
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(homeFeaturedProvider(widget.filter));
    final items = async.valueOrNull ?? const <FeaturedItem>[];
    final size = MediaQuery.sizeOf(context);
    _screenHeight = size.height;
    _itemCount = items.length;
    if (_page >= items.length) _page = 0;
    _report(items.isEmpty ? null : items[_page].artwork);

    if (items.isEmpty) {
      return SizedBox(
        height: 200,
        child: Center(
          child: async.isLoading
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(Insets.xl),
                  child: Text(
                    'Nothing to show here yet.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      );
    }

    // The card was sized by the leftover screen height when it lived in a
    // Column; in a scroll view it needs a real height. Portrait-ish like the
    // reference, but never taller than most of the screen (landscape/TV).
    final cardWidth = size.width * 0.92 - Insets.sm * 2;
    final height = math.min(cardWidth * 1.4, size.height * 0.62);

    return Column(
      children: [
        const SizedBox(height: Insets.sm),
        SizedBox(
          height: height,
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
        // Dots: the active one is an elongated pill.
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
        const SizedBox(height: Insets.sm),
      ],
    );
  }
}

/// The soft, blurred wash behind the top of Home (reference: the current
/// poster, blown up and blurred, darkened so the search/filter row stays
/// readable over any artwork, fading into the black below). Crossfades when
/// the carousel advances rather than snapping, since a hard cut behind
/// translucent chrome reads as a glitch.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url, required this.scroll});

  final ValueListenable<String?> url;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.8;

    final wash = SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: url,
            builder: (context, current, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: current == null
                  ? const SizedBox.shrink(key: ValueKey('none'))
                  : ImageFiltered(
                      key: ValueKey(current),
                      imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                      // Blurred beyond recognition anyway, so decode it
                      // tiny: the full-size poster was megabytes of bitmap
                      // for a smear.
                      child: CachedNetworkImage(
                        imageUrl: current,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        memCacheWidth: 200,
                        fadeInDuration: Duration.zero,
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.6, 1],
                colors: [
                  Color(0xB3000000),
                  Color(0xCC000000),
                  AppColors.background,
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: height,
      // Drifts up at half the scroll speed: the list slides over a
      // backdrop that is visibly leaving, and deeper rows sit on pure black.
      // Only the translation changes per frame; the blurred picture is not
      // rebuilt or re-rastered.
      child: AnimatedBuilder(
        animation: scroll,
        builder: (context, child) {
          final offset = scroll.hasClients ? scroll.offset : 0.0;
          final dy = (offset * 0.5).clamp(0.0, height);
          return Transform.translate(offset: Offset(0, -dy), child: child);
        },
        child: IgnorePointer(child: RepaintBoundary(child: wash)),
      ),
    );
  }
}

class _FeaturedCard extends ConsumerWidget {
  const _FeaturedCard({required this.item});

  final FeaturedItem item;

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
