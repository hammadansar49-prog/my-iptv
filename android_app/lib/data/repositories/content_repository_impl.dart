import 'dart:async';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_error.dart';
import '../../core/utils/logger.dart';
import '../../domain/repositories/repositories.dart';
import '../api/xtream_api.dart';
import '../models/content.dart';
import '../models/epg.dart';

/// A value plus when it was fetched.
class _Cached<T> {
  _Cached(this.value) : at = DateTime.now();
  final T value;
  final DateTime at;
  bool isFresh(Duration ttl) => DateTime.now().difference(at) < ttl;
}

/// Caching layer over [XtreamApi].
///
/// Spec §44 is explicit: fetch once, cache, display — never re-request on
/// scroll. The full catalogue is fetched per section on first use and then
/// filtered locally, because Xtream has no pagination and no server-side
/// search; asking the panel again per keystroke would be both slow and a
/// second provider connection.
class ContentRepositoryImpl implements ContentRepository {
  ContentRepositoryImpl({required XtreamApi api}) : _api = api;

  static const _tag = 'ContentRepository';

  final XtreamApi _api;

  final Map<ContentSection, _Cached<List<Category>>> _categories = {};
  _Cached<List<LiveChannel>>? _channels;
  _Cached<List<Movie>>? _movies;
  _Cached<List<Series>>? _series;

  final Map<int, _Cached<List<EpgProgramme>>> _epg = {};
  final Map<int, MovieDetail> _movieDetails = {};
  final Map<int, SeriesDetail> _seriesDetails = {};

  /// In-flight fetches, so two widgets asking at once share one request
  /// rather than opening two provider connections (spec §64 race safety).
  final Map<String, Future<dynamic>> _inFlight = {};

  Future<T> _once<T>(String key, Future<T> Function() body) {
    final existing = _inFlight[key];
    if (existing != null) return existing as Future<T>;
    // Block body, NOT `() => _inFlight.remove(key)`: remove() returns the
    // stored Future — which is this very `future` — and whenComplete waits
    // on any Future its callback returns. The arrow form therefore made
    // every catalogue future wait on itself forever: the data downloaded
    // and parsed fine, but Home/Movies/Series/Live/EPG never received it
    // and spun on "loading" indefinitely. This was the original bug.
    final future = body().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// Catalogue/EPG reads hit `player_api.php`'s plain JSON endpoints, which
  /// are separate from the stream connection slots the panel counts against
  /// `max_connections` (AUDIT.md §8 table: only playback + downloads go
  /// through `ConnectionGuard`). Routing these through the guard as well was
  /// a bug: on a `max_connections=1` account (the common case) every catalog
  /// fetch queued behind whatever was playing and behind each other with a
  /// 700ms handover gap between each, so Movies/Series/Live TV could spin
  /// loading for a very long time — or never finish while something was
  /// playing — even though the request itself would have succeeded
  /// instantly. Metadata reads run straight through, unthrottled.
  Future<T> _fetch<T>(String label, Future<T> Function() body) => body();

  @override
  Future<List<Category>> categories(ContentSection section) async {
    final cached = _categories[section];
    if (cached != null && cached.isFresh(Limits.catalogTtl)) return cached.value;

    return _once('categories:${section.name}', () async {
      final fetched = await _fetch('categories-${section.name}', () async {
        switch (section) {
          case ContentSection.live:
            return _api.liveCategories();
          case ContentSection.movies:
            return _api.vodCategories();
          case ContentSection.series:
            return _api.seriesCategories();
        }
      });
      final withAll = <Category>[Category.all, ...fetched];
      _categories[section] = _Cached(withAll);
      return withAll;
    });
  }

  @override
  Future<List<LiveChannel>> liveChannels({String? categoryId}) async {
    final all = await _allChannels();
    if (categoryId == null || categoryId.isEmpty) return all;
    return all.where((c) => c.categoryId == categoryId).toList();
  }

  Future<List<LiveChannel>> _allChannels({
    void Function(int, int)? onBytes,
  }) async {
    final cached = _channels;
    if (cached != null && cached.isFresh(Limits.catalogTtl)) return cached.value;
    return _once('channels', () async {
      final list = await _fetch(
          'live-streams', () => _api.liveStreams(onProgress: onBytes));
      Log.i(_tag, 'loaded ${list.length} channels');
      _channels = _Cached(list);
      return list;
    });
  }

  @override
  Future<List<Movie>> movies({String? categoryId}) async {
    final all = await _allMovies();
    if (categoryId == null || categoryId.isEmpty) return all;
    return all.where((m) => m.categoryId == categoryId).toList();
  }

  Future<List<Movie>> _allMovies({void Function(int, int)? onBytes}) async {
    final cached = _movies;
    if (cached != null && cached.isFresh(Limits.catalogTtl)) return cached.value;
    return _once('movies', () async {
      final list = await _fetch(
          'vod-streams', () => _api.vodStreams(onProgress: onBytes));
      Log.i(_tag, 'loaded ${list.length} movies');
      _movies = _Cached(list);
      return list;
    });
  }

  @override
  Future<List<Series>> seriesList({String? categoryId}) async {
    final all = await _allSeries();
    if (categoryId == null || categoryId.isEmpty) return all;
    return all.where((s) => s.categoryId == categoryId).toList();
  }

  Future<List<Series>> _allSeries({void Function(int, int)? onBytes}) async {
    final cached = _series;
    if (cached != null && cached.isFresh(Limits.catalogTtl)) return cached.value;
    return _once('series', () async {
      final list =
          await _fetch('series', () => _api.series(onProgress: onBytes));
      Log.i(_tag, 'loaded ${list.length} series');
      _series = _Cached(list);
      return list;
    });
  }

  @override
  Future<MovieDetail?> movieDetail(Movie movie) async {
    final cached = _movieDetails[movie.streamId];
    if (cached != null) return cached;
    return _once('movieDetail:${movie.streamId}', () async {
      final detail = await _fetch('vod-info', () => _api.vodInfo(movie));
      if (detail != null) _movieDetails[movie.streamId] = detail;
      return detail;
    });
  }

  @override
  Future<SeriesDetail?> seriesDetail(Series series) async {
    final cached = _seriesDetails[series.seriesId];
    if (cached != null) return cached;
    return _once('seriesDetail:${series.seriesId}', () async {
      final detail = await _fetch('series-info', () => _api.seriesInfo(series));
      if (detail != null) _seriesDetails[series.seriesId] = detail;
      return detail;
    });
  }

  // ---- Scoped search ------------------------------------------------------
  //
  // Each of these only ever touches its own list. Spec §18: search must
  // understand the current section, and must never mix sections.

  @override
  Future<List<LiveChannel>> searchChannels(String query) async {
    final q = _normalise(query);
    if (q.isEmpty) return const [];
    final all = await _allChannels();
    return _rank(all, q, (c) => c.name);
  }

  @override
  Future<List<Movie>> searchMovies(String query) async {
    final q = _normalise(query);
    if (q.isEmpty) return const [];
    final all = await _allMovies();
    return _rank(all, q, (m) => m.name);
  }

  @override
  Future<List<Series>> searchSeries(String query) async {
    final q = _normalise(query);
    if (q.isEmpty) return const [];
    final all = await _allSeries();
    return _rank(all, q, (s) => s.name);
  }

  static String _normalise(String s) => s.trim().toLowerCase();

  /// Prefix matches first, then word-boundary matches, then anything
  /// containing the query. Keeps "Avatar" above "The Last Avatar Special".
  static List<T> _rank<T>(List<T> items, String q, String Function(T) name) {
    final exact = <T>[];
    final prefix = <T>[];
    final word = <T>[];
    final contains = <T>[];
    for (final item in items) {
      final n = name(item).toLowerCase();
      if (n == q) {
        exact.add(item);
      } else if (n.startsWith(q)) {
        prefix.add(item);
      } else if (n.contains(' $q')) {
        word.add(item);
      } else if (n.contains(q)) {
        contains.add(item);
      }
    }
    return [...exact, ...prefix, ...word, ...contains];
  }

  // ---- EPG ----------------------------------------------------------------

  @override
  Future<ChannelGuide> guideFor(LiveChannel channel) async {
    final programmes = await _epgFor(channel);
    if (programmes.isEmpty) return ChannelGuide(channelKey: channel.key);
    return ChannelGuide.from(channel.key, programmes, DateTime.now());
  }

  @override
  Future<List<EpgProgramme>> fullGuide(LiveChannel channel) async {
    return _once('fullEpg:${channel.streamId}', () async {
      try {
        final list =
            await _fetch('epg-full', () => _api.fullEpg(channel.streamId));
        _epg[channel.streamId] = _Cached(list);
        return list;
      } on AppError catch (e) {
        Log.w(_tag, 'full EPG failed for ${channel.name}: ${e.message}');
        return const <EpgProgramme>[];
      }
    });
  }

  Future<List<EpgProgramme>> _epgFor(LiveChannel channel) async {
    final cached = _epg[channel.streamId];
    if (cached != null && cached.isFresh(Limits.epgTtl)) return cached.value;
    return _once('epg:${channel.streamId}', () async {
      try {
        final list =
            await _fetch('epg-short', () => _api.shortEpg(channel.streamId));
        _epg[channel.streamId] = _Cached(list);
        return list;
      } on AppError catch (e) {
        // No guide data is a normal state, not an error the user sees —
        // the PC app shows "no programme guide data from this provider".
        Log.w(_tag, 'EPG unavailable for ${channel.name}: ${e.message}');
        _epg[channel.streamId] = _Cached(const <EpgProgramme>[]);
        return const <EpgProgramme>[];
      }
    });
  }

  // ---- Stream URLs --------------------------------------------------------

  @override
  String liveUrl(LiveChannel channel, {String? ext}) =>
      _api.liveStreamUrl(channel.streamId, ext: ext ?? 'm3u8');

  @override
  String movieUrl(Movie movie) =>
      _api.movieStreamUrl(movie.streamId, ext: movie.ext);

  @override
  String episodeUrl(Episode episode) =>
      _api.episodeStreamUrl(episode.id, ext: episode.ext);

  @override
  Future<int> preload(
    ContentSection section, {
    void Function(int received, int total)? onBytes,
  }) async {
    switch (section) {
      case ContentSection.live:
        return (await _allChannels(onBytes: onBytes)).length;
      case ContentSection.movies:
        return (await _allMovies(onBytes: onBytes)).length;
      case ContentSection.series:
        return (await _allSeries(onBytes: onBytes)).length;
    }
  }

  @override
  Future<void> invalidate() async {
    _categories.clear();
    _channels = null;
    _movies = null;
    _series = null;
    _epg.clear();
    _movieDetails.clear();
    _seriesDetails.clear();
    Log.i(_tag, 'catalogue cache cleared');
  }
}
