import 'json.dart';

/// Which part of the app a piece of content belongs to. Drives scoped search
/// (spec §13/§15/§17/§18) and favorites grouping (spec §30).
enum ContentSection { live, movies, series }

/// `get_live_categories` / `get_vod_categories` / `get_series_categories`.
class Category {
  const Category({required this.id, required this.name, this.parentId});

  final String id;
  final String name;
  final String? parentId;

  /// Synthetic "everything" row shown first in every category list.
  static const all = Category(id: '', name: 'All');

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: asString(j['category_id']),
        name: asString(j['category_name'], 'Unnamed'),
        parentId: asStringOrNull(j['parent_id']),
      );

  @override
  bool operator ==(Object other) => other is Category && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// `get_live_streams`.
class LiveChannel {
  const LiveChannel({
    required this.streamId,
    required this.name,
    required this.categoryId,
    this.logo,
    this.epgChannelId,
    this.number,
    this.tvArchive = false,
    this.tvArchiveDuration = 0,
  });

  final int streamId;
  final String name;
  final String categoryId;
  final String? logo;

  /// Ties the channel to its EPG rows. Absent on many panels.
  final String? epgChannelId;

  final int? number;

  /// Panel supports catch-up for this channel (the "Catch-up" pill in the
  /// design screenshots). Standard Xtream fields.
  final bool tvArchive;

  /// How many days of catch-up the panel keeps. 0 means none.
  final int tvArchiveDuration;

  /// Only offer catch-up when the panel actually says it has some.
  bool get hasCatchup => tvArchive && tvArchiveDuration > 0;

  factory LiveChannel.fromJson(Map<String, dynamic> j) => LiveChannel(
        streamId: asInt(j['stream_id']),
        name: asString(j['name'], 'Unnamed channel'),
        categoryId: asString(j['category_id']),
        logo: asStringOrNull(j['stream_icon']),
        epgChannelId: asStringOrNull(j['epg_channel_id']),
        number: asIntOrNull(j['num']),
        tvArchive: asBool(j['tv_archive']),
        tvArchiveDuration: asInt(j['tv_archive_duration']),
      );

  /// Stable identity for favorites/history. Mirrors the PC app's
  /// `historyKey: 'live:{stream_id}'`.
  String get key => 'live:$streamId';
}

/// `get_vod_streams` row. The heavier `get_vod_info` detail lands in
/// [MovieDetail].
class Movie {
  const Movie({
    required this.streamId,
    required this.name,
    required this.categoryId,
    this.poster,
    this.containerExtension,
    this.rating,
    this.year,
    this.addedAt,
  });

  final int streamId;
  final String name;
  final String categoryId;
  final String? poster;

  /// MUST be used when present — hardcoding mp4 breaks mkv content
  /// (AUDIT.md §2).
  final String? containerExtension;

  final double? rating;
  final String? year;
  final DateTime? addedAt;

  factory Movie.fromJson(Map<String, dynamic> j) => Movie(
        streamId: asInt(j['stream_id']),
        name: asString(j['name'], 'Untitled'),
        categoryId: asString(j['category_id']),
        poster: asStringOrNull(j['stream_icon']) ?? asStringOrNull(j['cover']),
        containerExtension: asStringOrNull(j['container_extension']),
        rating: asDoubleOrNull(j['rating']),
        year: asStringOrNull(j['year']),
        addedAt: asUnixSeconds(j['added']),
      );

  String get key => 'movie:$streamId';
  String get ext => containerExtension ?? 'mp4';
}

/// `get_vod_info` -> `info`.
class MovieDetail {
  const MovieDetail({
    required this.movie,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.durationSeconds,
    this.backdrop,
    this.trailer,
  });

  final Movie movie;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final int? durationSeconds;
  final String? backdrop;
  final String? trailer;

  factory MovieDetail.fromJson(Movie base, Map<String, dynamic> j) {
    final info = asMap(j['info']);
    final movieData = asMap(j['movie_data']);
    // Panels disagree about where container_extension lives on the detail
    // response; prefer the detail value, fall back to the list row.
    final ext = asStringOrNull(movieData['container_extension']) ??
        base.containerExtension;

    final backdrops = info['backdrop_path'];
    final backdrop = backdrops is List && backdrops.isNotEmpty
        ? asStringOrNull(backdrops.first)
        : asStringOrNull(backdrops);

    return MovieDetail(
      movie: Movie(
        streamId: base.streamId,
        name: base.name,
        categoryId: base.categoryId,
        poster: asStringOrNull(info['movie_image']) ?? base.poster,
        containerExtension: ext,
        rating: asDoubleOrNull(info['rating']) ?? base.rating,
        year: asStringOrNull(info['releasedate'])?.split('-').first ?? base.year,
        addedAt: base.addedAt,
      ),
      plot: asStringOrNull(info['plot']) ?? asStringOrNull(info['description']),
      cast: asStringOrNull(info['cast']),
      director: asStringOrNull(info['director']),
      genre: asStringOrNull(info['genre']),
      releaseDate: asStringOrNull(info['releasedate']),
      durationSeconds: asIntOrNull(info['duration_secs']),
      backdrop: backdrop,
      trailer: asStringOrNull(info['youtube_trailer']),
    );
  }
}

/// `get_series` row.
class Series {
  const Series({
    required this.seriesId,
    required this.name,
    required this.categoryId,
    this.cover,
    this.plot,
    this.rating,
    this.year,
    this.lastModified,
  });

  final int seriesId;
  final String name;
  final String categoryId;
  final String? cover;
  final String? plot;
  final double? rating;
  final String? year;
  final DateTime? lastModified;

  factory Series.fromJson(Map<String, dynamic> j) => Series(
        seriesId: asInt(j['series_id']),
        name: asString(j['name'], 'Untitled'),
        categoryId: asString(j['category_id']),
        cover: asStringOrNull(j['cover']),
        plot: asStringOrNull(j['plot']),
        rating: asDoubleOrNull(j['rating']),
        year: asStringOrNull(j['year']) ??
            asStringOrNull(j['releaseDate'])?.split('-').first,
        lastModified: asUnixSeconds(j['last_modified']),
      );

  String get key => 'series:$seriesId';
}

/// One episode inside a season of `get_series_info`.
class Episode {
  const Episode({
    required this.id,
    required this.seriesId,
    required this.season,
    required this.episodeNumber,
    required this.title,
    this.containerExtension,
    this.plot,
    this.still,
    this.durationSeconds,
    this.rating,
  });

  /// Xtream episode ids are sometimes numeric strings; the stream URL wants
  /// whatever the panel gave, so it stays a String.
  final String id;
  final int seriesId;
  final int season;
  final int episodeNumber;
  final String title;
  final String? containerExtension;
  final String? plot;
  final String? still;
  final int? durationSeconds;
  final double? rating;

  factory Episode.fromJson(int seriesId, Map<String, dynamic> j) {
    final info = asMap(j['info']);
    return Episode(
      id: asString(j['id']),
      seriesId: seriesId,
      season: asInt(j['season'], asInt(info['season'])),
      episodeNumber: asInt(j['episode_num']),
      title: asString(j['title'], 'Episode ${asInt(j['episode_num'])}'),
      containerExtension: asStringOrNull(j['container_extension']),
      plot: asStringOrNull(info['plot']),
      still: asStringOrNull(info['movie_image']),
      durationSeconds: asIntOrNull(info['duration_secs']),
      rating: asDoubleOrNull(info['rating']),
    );
  }

  String get ext => containerExtension ?? 'mp4';
  String get key => 'episode:$id';

  /// "S01E02" — used in download filenames, matching the PC app's naming.
  String get tag =>
      'S${season.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';
}

/// `get_series_info`: the series plus its seasons/episodes.
class SeriesDetail {
  const SeriesDetail({
    required this.series,
    required this.seasons,
    this.cast,
    this.director,
    this.genre,
  });

  final Series series;

  /// Season number -> episodes, ordered.
  final Map<int, List<Episode>> seasons;

  final String? cast;
  final String? director;
  final String? genre;

  List<int> get seasonNumbers => seasons.keys.toList()..sort();

  int get episodeCount =>
      seasons.values.fold(0, (sum, list) => sum + list.length);

  /// The episode after [current] in playback order, crossing season
  /// boundaries. Null at the end of the series (spec §32 autoplay).
  Episode? nextAfter(Episode current) {
    final inSeason = seasons[current.season];
    if (inSeason != null) {
      final idx = inSeason.indexWhere((e) => e.id == current.id);
      if (idx >= 0 && idx + 1 < inSeason.length) return inSeason[idx + 1];
    }
    final numbers = seasonNumbers;
    final si = numbers.indexOf(current.season);
    for (var i = si + 1; i >= 0 && i < numbers.length; i++) {
      final next = seasons[numbers[i]];
      if (next != null && next.isNotEmpty) return next.first;
    }
    return null;
  }

  factory SeriesDetail.fromJson(Series base, Map<String, dynamic> j) {
    final info = asMap(j['info']);
    final rawEpisodes = j['episodes'];
    final seasons = <int, List<Episode>>{};

    // `episodes` is normally an object keyed by season number, but some
    // panels send an array. Both shapes have to work.
    void add(Episode e) => (seasons[e.season] ??= []).add(e);

    if (rawEpisodes is Map) {
      for (final entry in rawEpisodes.entries) {
        final seasonNo = asIntOrNull(entry.key) ?? 0;
        for (final raw in asMapList(entry.value)) {
          final e = Episode.fromJson(base.seriesId, raw);
          add(e.season == 0 && seasonNo != 0
              ? Episode(
                  id: e.id,
                  seriesId: e.seriesId,
                  season: seasonNo,
                  episodeNumber: e.episodeNumber,
                  title: e.title,
                  containerExtension: e.containerExtension,
                  plot: e.plot,
                  still: e.still,
                  durationSeconds: e.durationSeconds,
                  rating: e.rating,
                )
              : e);
        }
      }
    } else {
      for (final raw in asMapList(rawEpisodes)) {
        add(Episode.fromJson(base.seriesId, raw));
      }
    }

    for (final list in seasons.values) {
      list.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    }

    return SeriesDetail(
      series: Series(
        seriesId: base.seriesId,
        name: base.name,
        categoryId: base.categoryId,
        cover: asStringOrNull(info['cover']) ?? base.cover,
        plot: asStringOrNull(info['plot']) ?? base.plot,
        rating: asDoubleOrNull(info['rating']) ?? base.rating,
        year: base.year,
        lastModified: base.lastModified,
      ),
      seasons: seasons,
      cast: asStringOrNull(info['cast']),
      director: asStringOrNull(info['director']),
      genre: asStringOrNull(info['genre']),
    );
  }
}
