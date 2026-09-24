import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../../domain/repositories/repositories.dart';
import '../../services/player/playback_request.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';
import 'home_feed.dart';

/// Colours that only Home's rows use, straight from the reference.
abstract final class _HomeColors {
  static const pillFill = Color(0xFF1C1C1E);
  static const pillBorder = Color(0xFF2E2E30);
  static const placeholder = Color(0xFF1E1E20);
  static const placeholderInk = Color(0xFF3A3A3C);
  static const rankTab = Color(0xD90B0B0D);
  static const progressTrack = Color(0x59FFFFFF);
}

/// Genre chip gradients. Picked by position, so the same list always looks
/// the same and neighbouring chips never share a colour.
const _genreGradients = <List<Color>>[
  [Color(0xFF2563EB), Color(0xFF38BDF8)], // blue → sky
  [Color(0xFFEA580C), Color(0xFFFBBF24)], // orange → amber
  [Color(0xFF7C3AED), Color(0xFFEC4899)], // violet → pink
  [Color(0xFFC026D3), Color(0xFF4F46E5)], // magenta → indigo
  [Color(0xFF0D9488), Color(0xFF22C55E)], // teal → green
  [Color(0xFFDB2777), Color(0xFFFB7185)], // pink → rose
  [Color(0xFF9333EA), Color(0xFF3B82F6)], // purple → blue
  [Color(0xFFFF6B6B), Color(0xFFF97316)], // coral → orange
];

/// Every row's tile size, derived from the screen width once per build.
///
/// The reference is a phone: exactly three posters across. On a TV or a
/// tablet that would make each poster 500px+ wide, so wide screens fit more
/// per row instead of scaling the phone layout up.
class HomeMetrics {
  const HomeMetrics._({
    required this.posterWidth,
    required this.rankedWidth,
    required this.continueWidth,
    required this.channelWidth,
  });

  factory HomeMetrics.of(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final compact = w < 600;
    final perScreen = compact ? 3 : (w / 190).floor().clamp(4, 9).toInt();
    final poster = (w - 2 * side - (perScreen - 1) * gap) / perScreen;
    return HomeMetrics._(
      posterWidth: poster,
      rankedWidth: compact ? w * 0.37 : poster * 1.3,
      continueWidth: compact ? w * 0.42 : math.min(w * 0.3, 360),
      channelWidth: compact ? w * 0.40 : math.min(w * 0.25, 300),
    );
  }

  static const side = Insets.lg;
  static const gap = Insets.md;

  final double posterWidth;
  final double rankedWidth;
  final double continueWidth;
  final double channelWidth;

  double get posterHeight => posterWidth * 1.5;
  double get rankedHeight => rankedWidth * 1.5;
  double get continueHeight => continueWidth * 9 / 16;
  double get channelHeight => channelWidth * 10 / 16;
}

/// Opens a category the same way the category strip inside Movies/Series/
/// Live TV selects one, so those screens need no Home-specific entry point.
void openHomeCategory(
  BuildContext context,
  WidgetRef ref,
  ContentSection section,
  String categoryId,
) {
  ref.read(selectedCategoryProvider(section).notifier).state = categoryId;
  context.push(switch (section) {
    ContentSection.movies => Routes.movies,
    ContentSection.series => Routes.series,
    ContentSection.live => Routes.liveTv,
  });
}

// ---- Feed sliver -----------------------------------------------------------

/// The rows under the carousel. One lazily built sliver item per row; each
/// row lazily builds its own tiles, so a feed of hundreds of categories only
/// ever builds what is on screen.
class HomeFeedSliver extends ConsumerWidget {
  const HomeFeedSliver({super.key, required this.filter});

  final HomeFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeFeedProvider(filter));
    final rows = async.valueOrNull;
    if (rows != null) {
      return SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final row = rows[i];
          return HomeRowView(key: ValueKey('${filter.name}/${row.id}'), row: row);
        },
      );
    }
    if (async.hasError) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: ErrorBanner(
            message: 'Could not load the catalogue.',
            onRetry: () {
              for (final s in ContentSection.values) {
                ref.invalidate(categoriesProvider(s));
              }
              ref.invalidate(moviesProvider(''));
              ref.invalidate(seriesProvider(''));
              ref.invalidate(liveChannelsProvider(''));
            },
          ),
        ),
      );
    }
    return const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: Insets.xxl),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      ),
    );
  }
}

class HomeRowView extends StatelessWidget {
  const HomeRowView({super.key, required this.row});

  final HomeRow row;

  @override
  Widget build(BuildContext context) {
    return switch (row) {
      MovieCategoryRow(:final bucket) => _PosterCategoryRow(
          section: ContentSection.movies,
          category: bucket.category,
          count: bucket.count,
          itemCount: bucket.items.length,
          titleOf: (i) => bucket.items[i].name,
          artworkOf: (i) => bucket.items[i].poster,
          open: (context, i) =>
              context.push(Routes.movieDetail, extra: bucket.items[i]),
        ),
      SeriesCategoryRow(:final bucket) => _PosterCategoryRow(
          section: ContentSection.series,
          category: bucket.category,
          count: bucket.count,
          itemCount: bucket.items.length,
          titleOf: (i) => bucket.items[i].name,
          artworkOf: (i) => bucket.items[i].cover,
          open: (context, i) =>
              context.push(Routes.seriesDetail, extra: bucket.items[i]),
        ),
      ChannelCategoryRow(:final bucket) => _ChannelCategoryRow(bucket: bucket),
      RankedMoviesRow(:final title, :final items) => _RankedRow(
          storageKey: 'home/rank/movies',
          title: title,
          itemCount: items.length,
          titleOf: (i) => items[i].name,
          artworkOf: (i) => items[i].poster,
          open: (context, i) =>
              context.push(Routes.movieDetail, extra: items[i]),
        ),
      RankedSeriesRow(:final title, :final items) => _RankedRow(
          storageKey: 'home/rank/series',
          title: title,
          itemCount: items.length,
          titleOf: (i) => items[i].name,
          artworkOf: (i) => items[i].cover,
          open: (context, i) =>
              context.push(Routes.seriesDetail, extra: items[i]),
        ),
      GenresRow genres => _GenresBlock(row: genres),
    };
  }
}

// ---- Section header --------------------------------------------------------

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.chevron = true,
    this.onTap,
  });

  /// Shown exactly as the panel names it — panels use case deliberately
  /// ("EN | NETFLIX", "Kids") and forcing one breaks their own branding.
  final String title;
  final int? count;
  final bool chevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(
          HomeMetrics.side, 22, HomeMetrics.side, 10),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (chevron && onTap != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Icon(Icons.chevron_right_rounded,
                        color: AppColors.textPrimary, size: 22),
                  ),
              ],
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: Insets.md),
            CountPill(count: count!),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    // Own Material: the Scaffold's sits under the opaque backdrop, so an
    // InkWell painting there would never show its ripple or focus colour.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        focusColor: AppColors.accentSoft,
        child: content,
      ),
    );
  }
}

class CountPill extends StatelessWidget {
  const CountPill({super.key, required this.count});

  final int count;

  static final _format = NumberFormat.decimalPattern();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 28, minWidth: 28),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _HomeColors.pillFill,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: _HomeColors.pillBorder),
      ),
      child: Text(
        _format.format(count),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ---- Shared tile bits ------------------------------------------------------

/// What a Home tile shows when the panel's artwork is missing or broken: the
/// app mark, plus the title so the tile can still be told apart.
class PosterPlaceholder extends StatelessWidget {
  const PosterPlaceholder({
    super.key,
    this.title,
    this.titleOnTop = false,
    this.color = _HomeColors.placeholder,
  });

  final String? title;

  /// The ranked row's numeral covers the bottom of the tile.
  final bool titleOnTop;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = title?.trim();
    final hasTitle = label != null && label.isNotEmpty;
    return ColoredBox(
      color: color,
      child: LayoutBuilder(
        builder: (context, box) {
          final glyph =
              (math.min(box.maxWidth, box.maxHeight) * 0.3).clamp(16.0, 48.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: Alignment(0, hasTitle && !titleOnTop ? -0.2 : 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tv_rounded,
                        color: _HomeColors.placeholderInk, size: glyph),
                    Text(
                      'IPTV',
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(
                        color: _HomeColors.placeholderInk,
                        fontSize: glyph * 0.38,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasTitle)
                Positioned(
                  left: Insets.sm,
                  right: Insets.sm,
                  top: titleOnTop ? Insets.sm : null,
                  bottom: titleOnTop ? null : Insets.sm,
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: titleOnTop ? TextAlign.left : TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      height: 1.2,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Tap/focus layer laid over artwork. Its own transparent Material keeps the
/// ripple above the image instead of under it.
class _TapLayer extends StatelessWidget {
  const _TapLayer({
    required this.radius,
    required this.onTap,
    this.onLongPress,
    this.label,
  });

  final double radius;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(radius),
          focusColor: AppColors.accentSoft,
        ),
      ),
    );
  }
}

/// Horizontal lazy strip with a fixed extent per tile, so scrolling a row
/// never measures anything and only visible tiles are built.
class _Strip extends StatelessWidget {
  const _Strip({
    required this.storageKey,
    required this.height,
    required this.tileWidth,
    required this.itemCount,
    required this.itemBuilder,
  });

  final String storageKey;
  final double height;
  final double tileWidth;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    const gap = HomeMetrics.gap;
    final extent = tileWidth + gap;
    return SizedBox(
      height: height,
      child: ListView.builder(
        // Restores each row's horizontal offset when it scrolls back in.
        key: PageStorageKey<String>(storageKey),
        scrollDirection: Axis.horizontal,
        // The trailing gap is part of each extent; trim it from the end
        // padding so the last tile still sits 16px from the edge.
        padding: const EdgeInsets.only(
            left: HomeMetrics.side, right: HomeMetrics.side - gap),
        itemExtent: extent,
        cacheExtent: extent * 2,
        itemCount: itemCount,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(right: gap),
          child: itemBuilder(context, i),
        ),
      ),
    );
  }
}

// ---- Poster rows -----------------------------------------------------------

class _PosterCategoryRow extends ConsumerWidget {
  const _PosterCategoryRow({
    required this.section,
    required this.category,
    required this.count,
    required this.itemCount,
    required this.titleOf,
    required this.artworkOf,
    required this.open,
  });

  final ContentSection section;
  final Category category;
  final int count;
  final int itemCount;
  final String Function(int) titleOf;
  final String? Function(int) artworkOf;
  final void Function(BuildContext, int) open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = HomeMetrics.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: category.name,
          count: count,
          onTap: () => openHomeCategory(context, ref, section, category.id),
        ),
        _Strip(
          storageKey: 'home/${section.name}/${category.id}',
          height: m.posterHeight,
          tileWidth: m.posterWidth,
          itemCount: itemCount,
          itemBuilder: (context, i) {
            final title = titleOf(i);
            return Stack(
              children: [
                NetworkArtwork(
                  url: artworkOf(i),
                  width: m.posterWidth,
                  height: m.posterHeight,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  fallback: PosterPlaceholder(title: title),
                ),
                Positioned.fill(
                  child: _TapLayer(
                    radius: Radii.sm,
                    label: title,
                    onTap: () => open(context, i),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ---- Ranked "Recently Added" -----------------------------------------------

class _RankedRow extends StatelessWidget {
  const _RankedRow({
    required this.storageKey,
    required this.title,
    required this.itemCount,
    required this.titleOf,
    required this.artworkOf,
    required this.open,
  });

  final String storageKey;
  final String title;
  final int itemCount;
  final String Function(int) titleOf;
  final String? Function(int) artworkOf;
  final void Function(BuildContext, int) open;

  @override
  Widget build(BuildContext context) {
    final m = HomeMetrics.of(context);
    final numeral = (m.rankedWidth * 0.61).clamp(56.0, 120.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // No destination to open: no screen lists "newest" on its own.
        SectionHeader(title: title, count: itemCount, chevron: false),
        _Strip(
          storageKey: storageKey,
          height: m.rankedHeight,
          tileWidth: m.rankedWidth,
          itemCount: itemCount,
          itemBuilder: (context, i) {
            final name = titleOf(i);
            return Stack(
              children: [
                NetworkArtwork(
                  url: artworkOf(i),
                  width: m.rankedWidth,
                  height: m.rankedHeight,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  fallback: PosterPlaceholder(title: name, titleOnTop: true),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: _RankBadge(rank: i + 1, fontSize: numeral),
                ),
                Positioned.fill(
                  child: _TapLayer(
                    radius: Radii.sm,
                    label: '${i + 1}. $name',
                    onTap: () => open(context, i),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// The big outlined numeral on its dark tab, bottom-right of the poster.
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank, required this.fontSize});

  final int rank;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      height: 1,
      letterSpacing: -fontSize * 0.05,
    );
    final label = '$rank';
    // Fixed size regardless of the system font scale: it is artwork, and a
    // scaled-up "20" would not fit on the poster at all.
    return CustomPaint(
      painter: const _RankTabPainter(),
      child: Padding(
        padding: EdgeInsets.only(left: fontSize * 0.16, right: fontSize * 0.08),
        child: Stack(
          children: [
            Text(
              label,
              textScaler: TextScaler.noScaling,
              style: base.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = fontSize * 0.07
                  ..strokeJoin = StrokeJoin.round
                  ..color = const Color(0xE6000000),
              ),
            ),
            Text(
              label,
              textScaler: TextScaler.noScaling,
              style: base.copyWith(
                color: Colors.white,
                shadows: const [
                  Shadow(color: Color(0x99000000), blurRadius: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankTabPainter extends CustomPainter {
  const _RankTabPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Only the lower half: the top of the numeral stands up over the poster.
    final rect = Rect.fromLTRB(0, size.height * 0.52, size.width, size.height);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: const Radius.circular(Radii.lg),
        bottomRight: const Radius.circular(Radii.sm),
      ),
      Paint()..color = _HomeColors.rankTab,
    );
  }

  @override
  bool shouldRepaint(_RankTabPainter oldDelegate) => false;
}

// ---- Live channel rows -----------------------------------------------------

class _ChannelCategoryRow extends ConsumerWidget {
  const _ChannelCategoryRow({required this.bucket});

  final CategoryBucket<LiveChannel> bucket;

  static const _nameStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 12.5,
    height: 1.3,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = HomeMetrics.of(context);
    final w = m.channelWidth, h = m.channelHeight;
    const pad = Insets.md;
    final nameArea =
        6 + MediaQuery.textScalerOf(context).scale(_nameStyle.fontSize!) * 1.3 + 2;
    final items = bucket.items;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: bucket.category.name,
          count: bucket.count,
          onTap: () => openHomeCategory(
              context, ref, ContentSection.live, bucket.category.id),
        ),
        _Strip(
          storageKey: 'home/live/${bucket.category.id}',
          height: h + nameArea,
          tileWidth: w,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final channel = items[i];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: w,
                  height: h,
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(Radii.sm),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      // Live always goes through the inline screen
                      // (CLAUDE.md), never straight to the player.
                      onTap: () => context.push(Routes.liveTv, extra: channel),
                      focusColor: AppColors.accentSoft,
                      child: Padding(
                        padding: const EdgeInsets.all(pad),
                        child: NetworkArtwork(
                          url: channel.logo,
                          width: w - 2 * pad,
                          height: h - 2 * pad,
                          fit: BoxFit.contain,
                          borderRadius: BorderRadius.zero,
                          placeholderColor: Colors.transparent,
                          fallback: const PosterPlaceholder(
                              color: Colors.transparent),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _nameStyle,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ---- Genres ----------------------------------------------------------------

class _GenresBlock extends ConsumerWidget {
  const _GenresBlock({required this.row});

  final GenresRow row;

  static const _chipHeight = 52.0;
  static const _chipGap = 10.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = row.categories;
    // Two rows that scroll as one: each list item is a column holding the
    // top and bottom chip, so the block stays lazy with hundreds of
    // categories. The pair shares the wider chip's width.
    final columns = (categories.length + 1) ~/ 2;

    Widget chip(int column, int line) {
      final i = column * 2 + line;
      if (i >= categories.length) return const SizedBox(height: _chipHeight);
      final category = categories[i];
      return _GenreChip(
        label: category.name.toUpperCase(),
        colors: _genreGradients[(column + line * 3) % _genreGradients.length],
        onTap: () => openHomeCategory(context, ref, row.section, category.id),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Genres',
          count: categories.length,
          // Every category of the section, with its own chip strip.
          onTap: () => openHomeCategory(context, ref, row.section, ''),
        ),
        SizedBox(
          height: _chipHeight * 2 + _chipGap,
          child: ListView.builder(
            key: PageStorageKey<String>('home/genres/${row.section.name}'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(
                left: HomeMetrics.side, right: HomeMetrics.side - _chipGap),
            itemCount: columns,
            itemBuilder: (context, c) => Padding(
              padding: const EdgeInsets.only(right: _chipGap),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    chip(c, 0),
                    const SizedBox(height: _chipGap),
                    chip(c, 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({
    required this.label,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.md);
    return SizedBox(
      height: _GenresBlock._chipHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            focusColor: Colors.white24,
            child: ConstrainedBox(
              // Some panels name categories like sentences; cap the chip
              // rather than let one swallow the whole block.
              constraints: const BoxConstraints(maxWidth: 280),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Continue Watching -----------------------------------------------------

/// A history row that can actually be resumed, and how.
class _Resumable {
  const _Resumable(this.entry, this.section, this.download);

  final HistoryEntry entry;
  final ContentSection section;

  /// Set when the entry was played from Downloads: it resumes from the file.
  final DownloadItem? download;

  static const _downloadPrefix = 'download:';

  static _Resumable? from(HistoryEntry e, List<DownloadItem> downloads) {
    final replay = e.replay;
    if (replay != null) {
      if (replay.section == ContentSection.live) return null;
      return _Resumable(e, replay.section, null);
    }
    // Downloads record history under 'download:{id}' with no replay ref.
    // They can only resume while the finished file is still there.
    if (!e.key.startsWith(_downloadPrefix)) return null;
    final id = e.key.substring(_downloadPrefix.length);
    for (final d in downloads) {
      if (d.id == id && d.status == DownloadStatus.completed) {
        return _Resumable(
          e,
          d.isEpisode ? ContentSection.series : ContentSection.movies,
          d,
        );
      }
    }
    return null;
  }

  /// Rebuilt the way the detail screens build it, so the player's history,
  /// resume and next-episode logic see exactly the same request.
  PlaybackRequest? request(ContentRepository? repo) {
    final d = download;
    if (d != null) {
      return PlaybackRequest(
        url: d.url,
        localFile: d.filePath,
        title: entry.title,
        subtitle: entry.subtitle ?? '',
        thumb: entry.thumb,
        isLive: false,
        historyKey: entry.key,
        startAt: entry.resumeAt,
        section: section,
      );
    }
    final replay = entry.replay;
    if (replay == null || repo == null) return null;
    return PlaybackRequest(
      url: repo.replayUrl(replay),
      title: entry.title,
      subtitle: entry.subtitle ?? '',
      thumb: entry.thumb,
      isLive: false,
      historyKey: entry.key,
      startAt: entry.resumeAt,
      section: replay.section,
      replay: replay,
    );
  }

  String get secondaryLine {
    final sub = entry.subtitle;
    if (section == ContentSection.series && sub != null && sub.isNotEmpty) {
      return sub;
    }
    final left = entry.duration - entry.resumeAt;
    final mins = math.max(1, (left.inSeconds / 60).ceil());
    if (mins < 60) return '$mins min left';
    final h = mins ~/ 60, m = mins % 60;
    return m == 0 ? '${h}h left' : '${h}h ${m}m left';
  }
}

/// In-progress movies/episodes, most recent first. Watches the library on
/// its own so progress updates from the player rebuild only this row.
class ContinueWatchingSection extends ConsumerWidget {
  const ContinueWatchingSection({super.key, required this.filter});

  final HomeFilter filter;

  static const _titleStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const _subStyle = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 12,
    height: 1.25,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (filter == HomeFilter.liveTv) return const SizedBox.shrink();
    final history = ref.watch(continueWatchingProvider);
    if (history.isEmpty) return const SizedBox.shrink();

    // Read, not watched: download progress ticks must not rebuild this row.
    // Anything stale is caught again on tap.
    final downloads = ref.read(downloadManagerProvider).items;
    final items = <_Resumable>[];
    // One card per title: the same movie/episode played from Downloads, or
    // listed twice by the panel under another id, has its own history key.
    // History is most-recent-first, so the first one seen is the latest.
    final seen = <String>{};
    for (final e in history) {
      final r = _Resumable.from(e, downloads);
      if (r == null) continue;
      if (!seen.add(_identity(e))) continue;
      final keep = switch (filter) {
        HomeFilter.all => true,
        HomeFilter.movies || HomeFilter.ott =>
          r.section == ContentSection.movies,
        HomeFilter.series => r.section == ContentSection.series,
        HomeFilter.liveTv => false,
      };
      if (keep) items.add(r);
    }
    if (items.isEmpty) return const SizedBox.shrink();

    final m = HomeMetrics.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final textArea = 6 +
        scaler.scale(_titleStyle.fontSize!) * _titleStyle.height! +
        2 +
        scaler.scale(_subStyle.fontSize!) * _subStyle.height! +
        2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Continue Watching',
          count: items.length,
          chevron: false,
        ),
        _Strip(
          storageKey: 'home/continue',
          height: m.continueHeight + textArea,
          tileWidth: m.continueWidth,
          itemCount: items.length,
          itemBuilder: (context, i) => _ContinueCard(
            key: ValueKey(items[i].entry.key),
            item: items[i],
            width: m.continueWidth,
            imageHeight: m.continueHeight,
          ),
        ),
        const SizedBox(height: Insets.sm),
      ],
    );
  }
}

/// What makes two history rows "the same thing" for Continue Watching.
String _identity(HistoryEntry e) =>
    '${e.title.trim().toLowerCase()}|${(e.subtitle ?? '').trim().toLowerCase()}';

class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({
    super.key,
    required this.item,
    required this.width,
    required this.imageHeight,
  });

  final _Resumable item;
  final double width;
  final double imageHeight;

  static const _radius = 10.0;

  void _resume(BuildContext context, WidgetRef ref) {
    final request = item.request(ref.read(contentRepositoryProvider));
    if (request == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('This title can no longer be resumed.'),
        ));
      return;
    }
    context.push(Routes.player, extra: request);
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    final entry = item.entry;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.lg, 0, Insets.lg, Insets.sm),
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline_rounded,
                  color: AppColors.textPrimary),
              title: const Text('Remove from Continue Watching'),
              onTap: () {
                Navigator.of(sheet).pop();
                _remove(context, ref);
              },
            ),
            const SizedBox(height: Insets.sm),
          ],
        ),
      ),
    );
  }

  void _remove(BuildContext context, WidgetRef ref) {
    final entry = item.entry;
    // Older duplicates of the same title go too, or one would pop back up.
    final library = ref.read(libraryRepositoryProvider);
    final id = _identity(entry);
    for (final h in library.continueWatching()) {
      if (_identity(h) == id) library.removeHistory(h.key);
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed "${entry.title}" from Continue Watching'),
      ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = item.entry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: width,
          height: imageHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetworkArtwork(
                  url: entry.thumb,
                  width: width,
                  height: imageHeight,
                  borderRadius: BorderRadius.zero,
                  fallback: const PosterPlaceholder(),
                ),
                const Center(child: _PlayGlyph()),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 3,
                  child: _ProgressBar(value: entry.progress),
                ),
                Positioned.fill(
                  child: _TapLayer(
                    radius: _radius,
                    label: 'Resume ${entry.title}',
                    onTap: () => _resume(context, ref),
                    onLongPress: () => _showActions(context, ref),
                  ),
                ),
                // Above the tap layer so it wins the hit test.
                Positioned(
                  top: 4,
                  right: 4,
                  child: Semantics(
                    button: true,
                    label: 'Remove ${entry.title} from Continue Watching',
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.6),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _remove(context, ref),
                        child: const SizedBox.square(
                          dimension: 30,
                          child: Icon(Icons.close_rounded,
                              size: 17, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ContinueWatchingSection._titleStyle,
        ),
        const SizedBox(height: 2),
        Text(
          item.secondaryLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ContinueWatchingSection._subStyle,
        ),
      ],
    );
  }
}

class _PlayGlyph extends StatelessWidget {
  const _PlayGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0x73000000),
        border: Border.all(color: const Color(0x66FFFFFF)),
      ),
      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _HomeColors.progressTrack,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0.0, 1.0),
          heightFactor: 1,
          child: const ColoredBox(color: AppColors.accent),
        ),
      ),
    );
  }
}
