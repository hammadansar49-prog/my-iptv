import 'dart:convert';

class Account {
  final String id;
  final String type; // 'xtream' | 'm3u'
  final String name;
  final String url;
  final String username;
  final String password;

  Account({
    required this.id,
    required this.type,
    required this.name,
    this.url = '',
    this.username = '',
    this.password = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'url': url,
        'username': username,
        'password': password,
      };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'],
        type: j['type'],
        name: j['name'] ?? '',
        url: j['url'] ?? '',
        username: j['username'] ?? '',
        password: j['password'] ?? '',
      );
}

class PlayableItem {
  final String id;          // stream_id / series_id as string
  final String name;
  final String thumb;
  final double rating;
  final String containerExt;
  final Map<String, dynamic> raw;

  PlayableItem({
    required this.id,
    required this.name,
    this.thumb = '',
    this.rating = 0,
    this.containerExt = 'mp4',
    this.raw = const {},
  });

  factory PlayableItem.fromLive(Map<String, dynamic> j) => PlayableItem(
        id: '${j['stream_id']}',
        name: j['name'] ?? 'Unknown',
        thumb: j['stream_icon'] ?? '',
        raw: j,
      );

  factory PlayableItem.fromVod(Map<String, dynamic> j) => PlayableItem(
        id: '${j['stream_id']}',
        name: j['name'] ?? 'Unknown',
        thumb: j['stream_icon'] ?? j['cover'] ?? '',
        rating: double.tryParse('${j['rating_5based'] ?? j['rating'] ?? 0}') ?? 0,
        containerExt: j['container_extension'] ?? 'mp4',
        raw: j,
      );

  factory PlayableItem.fromSeries(Map<String, dynamic> j) => PlayableItem(
        id: '${j['series_id']}',
        name: j['name'] ?? 'Unknown',
        thumb: j['cover'] ?? '',
        rating: double.tryParse('${j['rating_5based'] ?? j['rating'] ?? 0}') ?? 0,
        raw: j,
      );
}

// Same rule as extractYear()/sortByRecency() in the PC app's renderer.js:
// a 4-digit year found in the name wins; otherwise fall back to the
// provider's own release_date (series) or added (VOD, epoch seconds).
// Items with no detectable year sink to the bottom instead of cluttering the
// top of Movies/Series with undated junk, without ever dropping an item.
int? _extractYear(PlayableItem it, String section) {
  final m = RegExp(r'(19|20)\d{2}').firstMatch(it.name);
  if (m != null) return int.parse(m.group(0)!);
  if (section == 'series') {
    final rd = it.raw['release_date']?.toString();
    if (rd != null && rd.length >= 4) {
      final y = int.tryParse(rd.substring(0, 4));
      if (y != null) return y;
    }
  } else {
    final added = it.raw['added'];
    final ts = added == null ? null : int.tryParse(added.toString());
    if (ts != null && ts > 0) return DateTime.fromMillisecondsSinceEpoch(ts * 1000).year;
  }
  return null;
}

List<PlayableItem> sortByRecency(List<PlayableItem> items, String section) {
  final indexed = items.asMap().entries.toList()
    ..sort((a, b) {
      final ya = _extractYear(a.value, section);
      final yb = _extractYear(b.value, section);
      if (ya == null && yb == null) return a.key.compareTo(b.key);
      if (ya == null) return 1;
      if (yb == null) return -1;
      if (ya != yb) return yb.compareTo(ya);
      return a.key.compareTo(b.key);
    });
  return indexed.map((e) => e.value).toList();
}

class Category {
  final String id;
  final String name;
  Category({required this.id, required this.name});
  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(id: '${j['category_id']}', name: j['category_name'] ?? '');
}

/// Everything the player needs to start playback and everything History /
/// Favorites need to redisplay + resume the same item later.
class PlayRequest {
  final String url;
  final bool isLive;
  final String type; // live | movie | episode
  final String title;
  final String subtitle;
  final String thumb;
  final String historyKey;
  double resumeAt;

  /// A downloaded file played from the phone (no provider involved).
  final bool local;

  /// For episodes: the season's episode list and this episode's position in
  /// it, so the next one can start by itself when this one ends.
  final List<PlayRequest>? playlist;
  final int playlistIndex;

  PlayRequest({
    required this.url,
    required this.isLive,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.thumb,
    required this.historyKey,
    this.resumeAt = 0,
    this.local = false,
    this.playlist,
    this.playlistIndex = -1,
  });

  bool get downloadable => !isLive && !local && url.startsWith('http');
}

/// One programme in a channel's guide.
class EpgEntry {
  final String title;
  final String description;
  final int start; // unix seconds
  final int stop;

  EpgEntry({required this.title, required this.description, required this.start, required this.stop});

  static String _b64(dynamic v) {
    final s = '${v ?? ''}';
    if (s.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } catch (_) {
      return s;
    }
  }

  factory EpgEntry.fromJson(Map<String, dynamic> j) => EpgEntry(
        title: _b64(j['title']),
        description: _b64(j['description']),
        start: int.tryParse('${j['start_timestamp'] ?? ''}') ?? 0,
        stop: int.tryParse('${j['stop_timestamp'] ?? ''}') ?? 0,
      );

  bool isNow(int nowSec) => start <= nowSec && nowSec < stop;
}

/// A film or episode saved to the phone for watching offline.
class DownloadItem {
  final String id;
  final String url;
  final String title;
  final String subtitle;
  final String type; // movie | episode
  final String thumb;
  String filePath;
  int totalBytes;
  int receivedBytes;
  String status; // queued | downloading | paused | failed | completed
  String error;
  final int addedAt;
  int completedAt;

  // Live figures, not saved.
  double speed = 0; // bytes per second
  double? get eta => status == 'downloading' && speed > 0 && totalBytes > 0 ? (totalBytes - receivedBytes) / speed : null;
  double get progress => totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0, 1) : (status == 'completed' ? 1 : 0);

  DownloadItem({
    required this.id,
    required this.url,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.thumb,
    required this.filePath,
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.status = 'queued',
    this.error = '',
    required this.addedAt,
    this.completedAt = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id, 'url': url, 'title': title, 'subtitle': subtitle, 'type': type, 'thumb': thumb,
        'filePath': filePath, 'totalBytes': totalBytes, 'receivedBytes': receivedBytes,
        'status': status, 'error': error, 'addedAt': addedAt, 'completedAt': completedAt,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        id: j['id'],
        url: j['url'] ?? '',
        title: j['title'] ?? '',
        subtitle: j['subtitle'] ?? '',
        type: j['type'] ?? 'movie',
        thumb: j['thumb'] ?? '',
        filePath: j['filePath'] ?? '',
        totalBytes: j['totalBytes'] ?? 0,
        receivedBytes: j['receivedBytes'] ?? 0,
        status: j['status'] ?? 'queued',
        error: j['error'] ?? '',
        addedAt: j['addedAt'] ?? 0,
        completedAt: j['completedAt'] ?? 0,
      );
}

class HistoryEntry {
  final String key;
  final String type;
  final String title;
  final String subtitle;
  final String thumb;
  final String url;
  final bool isLive;
  double resumeAt;
  double duration;
  int updatedAt;

  HistoryEntry({
    required this.key,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.thumb,
    required this.url,
    required this.isLive,
    this.resumeAt = 0,
    this.duration = 0,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'type': type,
        'title': title,
        'subtitle': subtitle,
        'thumb': thumb,
        'url': url,
        'isLive': isLive,
        'resumeAt': resumeAt,
        'duration': duration,
        'updatedAt': updatedAt,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        key: j['key'],
        type: j['type'] ?? '',
        title: j['title'] ?? '',
        subtitle: j['subtitle'] ?? '',
        thumb: j['thumb'] ?? '',
        url: j['url'] ?? '',
        isLive: j['isLive'] ?? false,
        resumeAt: (j['resumeAt'] ?? 0).toDouble(),
        duration: (j['duration'] ?? 0).toDouble(),
        updatedAt: j['updatedAt'] ?? 0,
      );

  double get progressPct => duration > 0 ? (resumeAt / duration).clamp(0, 1) : 0;
}

class FavoriteEntry {
  final String key;
  final String section; // live | movies | series
  final PlayableItem item;
  FavoriteEntry({required this.key, required this.section, required this.item});

  Map<String, dynamic> toJson() => {
        'key': key,
        'section': section,
        'item': item.raw,
      };

  factory FavoriteEntry.fromJson(Map<String, dynamic> j) {
    final section = j['section'];
    final raw = Map<String, dynamic>.from(j['item']);
    final item = section == 'live'
        ? PlayableItem.fromLive(raw)
        : section == 'movies'
            ? PlayableItem.fromVod(raw)
            : PlayableItem.fromSeries(raw);
    return FavoriteEntry(key: j['key'], section: section, item: item);
  }
}
