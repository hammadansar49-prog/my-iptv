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

  PlayRequest({
    required this.url,
    required this.isLive,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.thumb,
    required this.historyKey,
    this.resumeAt = 0,
  });
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
