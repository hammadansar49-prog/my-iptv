import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/content.dart';
import '../providers.dart';

/// Which kind of content the home feed is showing.
enum HomeFilter { all, movies, series, liveTv, ott }

/// Row sizes for Home. Named so the feed builder and the widgets agree.
abstract final class HomeLimits {
  /// Posters per category row. The full category is one tap away on the
  /// header, so more than this is just memory spent on things never seen.
  static const rowItems = 30;

  /// The ranked "Recently Added" row (Netflix top-N style).
  static const ranked = 20;

  /// The Genres block goes after this many category rows.
  static const genresAfter = 4;

  static const featured = 10;
}

/// One category's slice of the catalogue: its size and the newest items.
class CategoryBucket<T> {
  const CategoryBucket(this.category, this.count, this.items);

  final Category category;

  /// Everything in the category, not just [items] — the header's count pill.
  final int count;

  /// At most [HomeLimits.rowItems], newest first where the panel dates them.
  final List<T> items;
}

/// A whole section grouped once for Home: non-empty categories in the
/// panel's order, plus the newest titles across the section.
class SectionIndex<T> {
  const SectionIndex({required this.buckets, required this.newest});

  final List<CategoryBucket<T>> buckets;
  final List<T> newest;

  List<Category> get categories => [for (final b in buckets) b.category];
}

// ---- Indexing --------------------------------------------------------------
//
// 69k movies on the real test account. Everything below runs once per
// catalogue list (the providers only recompute when the list itself is
// replaced), never inside a build method: sorting the full movie list per
// build was a visible stall on every carousel page change.

/// Indices of [keys] newest-first; undated rows (-1) last. Ties fall back to
/// the panel's own order so the result is stable between runs.
Int32List _newestFirst(Int64List keys) {
  final order = List<int>.generate(keys.length, (i) => i);
  order.sort((a, b) {
    final c = keys[b].compareTo(keys[a]);
    return c != 0 ? c : a - b;
  });
  return Int32List.fromList(order);
}

/// Only the sort crosses to another isolate, and only as plain integers:
/// copying 69k model objects across would cost as much as the sort itself.
/// Small lists are not worth the isolate spawn.
Future<Int32List> _orderNewestFirst(Int64List keys) {
  if (keys.length < 4000) return Future.value(_newestFirst(keys));
  return compute(_newestFirst, keys, debugLabel: 'home-newest-first');
}

SectionIndex<T> _buildIndex<T>({
  required List<T> items,
  required List<Category> categories,
  required String Function(T) categoryOf,
  Int32List? order,
  Int64List? keys,
}) {
  final counts = <String, int>{};
  final heads = <String, List<T>>{};

  void visit(T item) {
    final id = categoryOf(item);
    counts[id] = (counts[id] ?? 0) + 1;
    final head = heads[id] ??= <T>[];
    if (head.length < HomeLimits.rowItems) head.add(item);
  }

  if (order == null) {
    for (final item in items) {
      visit(item);
    }
  } else {
    for (final i in order) {
      visit(items[i]);
    }
  }

  final buckets = <CategoryBucket<T>>[];
  final seen = <String>{};
  for (final c in categories) {
    // Category.all is synthetic; a panel can also list a category twice.
    if (c.id.isEmpty || !seen.add(c.id)) continue;
    final n = counts[c.id] ?? 0;
    if (n == 0) continue;
    buckets.add(CategoryBucket<T>(c, n, heads[c.id]!));
  }

  final newest = <T>[];
  if (order != null && keys != null) {
    for (final i in order) {
      // Undated rows sort last; stopping there keeps "Recently Added"
      // honest on a panel that sends no dates at all.
      if (keys[i] < 0 || newest.length == HomeLimits.ranked) break;
      newest.add(items[i]);
    }
  }

  return SectionIndex<T>(buckets: buckets, newest: newest);
}

/// Categories failing is not fatal for Home — the newest-titles row and the
/// carousel still work without them.
Future<List<Category>> _categoriesOrEmpty(Ref ref, ContentSection section) =>
    ref.watch(categoriesProvider(section).future).then(
          (v) => v,
          onError: (Object _) => const <Category>[],
        );

final movieIndexProvider = FutureProvider<SectionIndex<Movie>>((ref) async {
  // Both futures are taken before the first await so neither dependency is
  // registered after an async gap.
  final categoriesF = _categoriesOrEmpty(ref, ContentSection.movies);
  final movies = await ref.watch(moviesProvider('').future);
  final categories = await categoriesF;

  final keys = Int64List(movies.length);
  for (var i = 0; i < movies.length; i++) {
    keys[i] = movies[i].addedAt?.millisecondsSinceEpoch ?? -1;
  }
  final order = await _orderNewestFirst(keys);
  return _buildIndex<Movie>(
    items: movies,
    categories: categories,
    categoryOf: (m) => m.categoryId,
    order: order,
    keys: keys,
  );
});

final seriesIndexProvider = FutureProvider<SectionIndex<Series>>((ref) async {
  final categoriesF = _categoriesOrEmpty(ref, ContentSection.series);
  final series = await ref.watch(seriesProvider('').future);
  final categories = await categoriesF;

  final keys = Int64List(series.length);
  for (var i = 0; i < series.length; i++) {
    keys[i] = series[i].lastModified?.millisecondsSinceEpoch ?? -1;
  }
  final order = await _orderNewestFirst(keys);
  return _buildIndex<Series>(
    items: series,
    categories: categories,
    categoryOf: (s) => s.categoryId,
    order: order,
    keys: keys,
  );
});

/// Live rows keep the panel's channel order — that is the numbering people
/// know their channels by, and there is no "added" date to rank on.
final liveIndexProvider =
    FutureProvider<SectionIndex<LiveChannel>>((ref) async {
  final categoriesF = _categoriesOrEmpty(ref, ContentSection.live);
  final channels = await ref.watch(liveChannelsProvider('').future);
  final categories = await categoriesF;
  return _buildIndex<LiveChannel>(
    items: channels,
    categories: categories,
    categoryOf: (c) => c.categoryId,
  );
});

// ---- Feed rows -------------------------------------------------------------

/// One vertical entry in the Home feed.
sealed class HomeRow {
  const HomeRow(this.id);

  /// Stable within a filter, so a row keeps its widget state (and restored
  /// horizontal offset) across rebuilds.
  final String id;
}

final class MovieCategoryRow extends HomeRow {
  MovieCategoryRow(this.bucket) : super('m:${bucket.category.id}');
  final CategoryBucket<Movie> bucket;
}

final class SeriesCategoryRow extends HomeRow {
  SeriesCategoryRow(this.bucket) : super('s:${bucket.category.id}');
  final CategoryBucket<Series> bucket;
}

final class ChannelCategoryRow extends HomeRow {
  ChannelCategoryRow(this.bucket) : super('l:${bucket.category.id}');
  final CategoryBucket<LiveChannel> bucket;
}

final class RankedMoviesRow extends HomeRow {
  const RankedMoviesRow(this.title, this.items) : super('rank:m');
  final String title;
  final List<Movie> items;
}

final class RankedSeriesRow extends HomeRow {
  const RankedSeriesRow(this.title, this.items) : super('rank:s');
  final String title;
  final List<Series> items;
}

final class GenresRow extends HomeRow {
  GenresRow(this.section, this.categories) : super('genres:${section.name}');
  final ContentSection section;
  final List<Category> categories;
}

/// Category rows with the ranked row after the first and the Genres block
/// after the [HomeLimits.genresAfter]th.
List<HomeRow> _interleave(
  List<HomeRow> categoryRows, {
  HomeRow? afterFirst,
  HomeRow? genres,
  List<HomeRow> leading = const [],
}) {
  final out = <HomeRow>[...leading];
  for (var i = 0; i < categoryRows.length; i++) {
    out.add(categoryRows[i]);
    if (i == 0 && afterFirst != null) out.add(afterFirst);
    if (i == HomeLimits.genresAfter - 1 && genres != null) out.add(genres);
  }
  if (categoryRows.isEmpty && afterFirst != null) out.add(afterFirst);
  // Fewer rows than the Genres slot: it still belongs somewhere.
  if (categoryRows.isNotEmpty &&
      categoryRows.length < HomeLimits.genresAfter &&
      genres != null) {
    out.add(genres);
  }
  return out;
}

GenresRow? _genres(ContentSection section, SectionIndex<Object?> index) =>
    index.buckets.isEmpty ? null : GenresRow(section, index.categories);

List<HomeRow> _moviesFeed(SectionIndex<Movie> m) => _interleave(
      [for (final b in m.buckets) MovieCategoryRow(b)],
      afterFirst:
          m.newest.isEmpty ? null : RankedMoviesRow('Recently Added', m.newest),
      genres: _genres(ContentSection.movies, m),
    );

List<HomeRow> _seriesFeed(SectionIndex<Series> s) => _interleave(
      [for (final b in s.buckets) SeriesCategoryRow(b)],
      afterFirst:
          s.newest.isEmpty ? null : RankedSeriesRow('Recently Added', s.newest),
      genres: _genres(ContentSection.series, s),
    );

List<HomeRow> _liveFeed(SectionIndex<LiveChannel> l) => _interleave(
      [for (final b in l.buckets) ChannelCategoryRow(b)],
      genres: _genres(ContentSection.live, l),
    );

List<HomeRow> _allFeed(SectionIndex<Movie> m, SectionIndex<Series> s) =>
    _interleave(
      [
        for (final b in m.buckets) MovieCategoryRow(b),
        for (final b in s.buckets) SeriesCategoryRow(b),
      ],
      leading: [
        if (m.newest.isNotEmpty) RankedMoviesRow('Recently Added', m.newest),
        if (s.newest.isNotEmpty)
          RankedSeriesRow('Recently Added Series', s.newest),
      ],
      genres: _genres(ContentSection.movies, m),
    );

AsyncValue<R> _both<A, B, R>(
  AsyncValue<A> a,
  AsyncValue<B> b,
  R Function(A, B) combine,
) {
  if (a.hasValue && b.hasValue) {
    return AsyncData(combine(a.requireValue, b.requireValue));
  }
  if (a.hasError) {
    return AsyncError<R>(a.error!, a.stackTrace ?? StackTrace.current);
  }
  if (b.hasError) {
    return AsyncError<R>(b.error!, b.stackTrace ?? StackTrace.current);
  }
  return AsyncLoading<R>();
}

/// The rows under the carousel for one filter. Cached per filter, rebuilt
/// only when an underlying index is.
final homeFeedProvider =
    Provider.family<AsyncValue<List<HomeRow>>, HomeFilter>((ref, filter) {
  switch (filter) {
    case HomeFilter.movies:
    case HomeFilter.ott:
      return ref.watch(movieIndexProvider).whenData(_moviesFeed);
    case HomeFilter.series:
      return ref.watch(seriesIndexProvider).whenData(_seriesFeed);
    case HomeFilter.liveTv:
      return ref.watch(liveIndexProvider).whenData(_liveFeed);
    case HomeFilter.all:
      return _both(
        ref.watch(movieIndexProvider),
        ref.watch(seriesIndexProvider),
        _allFeed,
      );
  }
});

// ---- Carousel --------------------------------------------------------------

class FeaturedItem {
  const FeaturedItem({
    required this.title,
    required this.category,
    required this.artwork,
    this.movie,
    this.series,
    this.channel,
  });

  factory FeaturedItem.movie(Movie m) => FeaturedItem(
        title: m.name,
        category: [if (m.year != null) m.year!, 'Movie'].join(' / '),
        artwork: m.poster,
        movie: m,
      );

  factory FeaturedItem.series(Series s) => FeaturedItem(
        title: s.name,
        category: [if (s.year != null) s.year!, 'Series'].join(' / '),
        artwork: s.cover,
        series: s,
      );

  factory FeaturedItem.channel(LiveChannel c) => FeaturedItem(
        title: c.name,
        category: 'Live TV',
        artwork: c.logo,
        channel: c,
      );

  final String title;
  final String category;
  final String? artwork;
  final Movie? movie;
  final Series? series;
  final LiveChannel? channel;
}

/// The carousel's entries, from the real catalogue.
///
/// "OTT" has no counterpart in the Xtream API — there is no such field in
/// any response (AUDIT.md §2). Rather than invent one, the pill maps to the
/// newest VOD additions, which is the closest honest reading.
final homeFeaturedProvider =
    Provider.family<AsyncValue<List<FeaturedItem>>, HomeFilter>((ref, filter) {
  List<FeaturedItem> newestMovies(SectionIndex<Movie> m, int n) =>
      [for (final x in m.newest.take(n)) FeaturedItem.movie(x)];
  List<FeaturedItem> firstSeries(List<Series> s, int n) =>
      [for (final x in s.take(n)) FeaturedItem.series(x)];

  switch (filter) {
    case HomeFilter.movies:
    case HomeFilter.ott:
      return ref
          .watch(movieIndexProvider)
          .whenData((m) => newestMovies(m, HomeLimits.featured));
    case HomeFilter.series:
      return ref
          .watch(seriesProvider(''))
          .whenData((s) => firstSeries(s, HomeLimits.featured));
    case HomeFilter.liveTv:
      return ref.watch(liveChannelsProvider('')).whenData((c) => [
            for (final x in c.take(HomeLimits.featured)) FeaturedItem.channel(x)
          ]);
    case HomeFilter.all:
      const half = HomeLimits.featured ~/ 2;
      return _both(
        ref.watch(movieIndexProvider),
        ref.watch(seriesProvider('')),
        (SectionIndex<Movie> m, List<Series> s) =>
            [...newestMovies(m, half), ...firstSeries(s, half)],
      );
  }
});
