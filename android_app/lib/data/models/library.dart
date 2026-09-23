import '../../core/constants/app_constants.dart';
import 'content.dart';
import 'json.dart';

/// A favorited item. Local only — the backend does not sync favorites
/// (AUDIT.md §4, spec §30 permits local persistence).
class FavoriteEntry {
  const FavoriteEntry({
    required this.key,
    required this.section,
    required this.title,
    required this.refId,
    this.thumb,
    this.subtitle,
    required this.addedAt,
  });

  /// "{section}:{id}" — same shape as the PC app's `favKey`.
  final String key;
  final ContentSection section;
  final String title;

  /// stream_id / series_id, as a string so both fit.
  final String refId;

  final String? thumb;
  final String? subtitle;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'key': key,
        'section': section.name,
        'title': title,
        'refId': refId,
        'thumb': thumb,
        'subtitle': subtitle,
        'addedAt': addedAt.millisecondsSinceEpoch,
      };

  factory FavoriteEntry.fromJson(Map<String, dynamic> j) => FavoriteEntry(
        key: asString(j['key']),
        section: ContentSection.values.firstWhere(
          (s) => s.name == asString(j['section']),
          orElse: () => ContentSection.live,
        ),
        title: asString(j['title'], 'Untitled'),
        refId: asString(j['refId']),
        thumb: asStringOrNull(j['thumb']),
        subtitle: asStringOrNull(j['subtitle']),
        addedAt: asUnixMillis(j['addedAt']) ?? DateTime.now(),
      );
}

/// Enough context to recreate playback from the history list — the PC app's
/// `replay` field.
class PlaybackRef {
  const PlaybackRef({
    required this.section,
    required this.streamId,
    this.seriesId,
    this.season,
    this.episodeId,
    this.ext,
  });

  final ContentSection section;
  final String streamId;
  final int? seriesId;
  final int? season;
  final String? episodeId;
  final String? ext;

  Map<String, dynamic> toJson() => {
        'section': section.name,
        'streamId': streamId,
        'seriesId': seriesId,
        'season': season,
        'episodeId': episodeId,
        'ext': ext,
      };

  factory PlaybackRef.fromJson(Map<String, dynamic> j) => PlaybackRef(
        section: ContentSection.values.firstWhere(
          (s) => s.name == asString(j['section']),
          orElse: () => ContentSection.movies,
        ),
        streamId: asString(j['streamId']),
        seriesId: asIntOrNull(j['seriesId']),
        season: asIntOrNull(j['season']),
        episodeId: asStringOrNull(j['episodeId']),
        ext: asStringOrNull(j['ext']),
      );
}

/// One watch-history row. Capped at [Limits.historyEntries], most recent
/// first, exactly like the PC app's `upsertHistory`.
class HistoryEntry {
  const HistoryEntry({
    required this.key,
    required this.title,
    required this.isLive,
    required this.updatedAt,
    this.subtitle,
    this.thumb,
    this.resumeAt = Duration.zero,
    this.duration = Duration.zero,
    this.replay,
  });

  final String key;
  final String title;
  final String? subtitle;
  final String? thumb;
  final bool isLive;
  final Duration resumeAt;
  final Duration duration;
  final PlaybackRef? replay;
  final DateTime updatedAt;

  /// The PC app's Continue Watching predicate, reproduced exactly:
  /// `!isLive && duration > 0 && resumeAt > 5 && resumeAt < duration * 0.95`.
  bool get isContinueWatching =>
      !isLive &&
      duration > Duration.zero &&
      resumeAt.inSeconds > Playback.resumeMinSeconds &&
      resumeAt.inMilliseconds <
          duration.inMilliseconds * Playback.resumeMaxFraction;

  /// Played to (nearly) the end — past the point where resuming stops
  /// making sense. Drives the "WATCHED" mark on episodes and movies.
  bool get isWatched =>
      !isLive &&
      duration > Duration.zero &&
      resumeAt.inMilliseconds >=
          duration.inMilliseconds * Playback.resumeMaxFraction;

  double get progress {
    if (duration <= Duration.zero) return 0;
    final p = resumeAt.inMilliseconds / duration.inMilliseconds;
    return p.clamp(0.0, 1.0);
  }

  HistoryEntry copyWith({
    Duration? resumeAt,
    Duration? duration,
    DateTime? updatedAt,
  }) =>
      HistoryEntry(
        key: key,
        title: title,
        subtitle: subtitle,
        thumb: thumb,
        isLive: isLive,
        resumeAt: resumeAt ?? this.resumeAt,
        duration: duration ?? this.duration,
        replay: replay,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'subtitle': subtitle,
        'thumb': thumb,
        'isLive': isLive,
        // Live rows always store zero, matching the PC app.
        'resumeAt': isLive ? 0 : resumeAt.inMilliseconds,
        'duration': isLive ? 0 : duration.inMilliseconds,
        'replay': replay?.toJson(),
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) {
    final replay = j['replay'];
    return HistoryEntry(
      key: asString(j['key']),
      title: asString(j['title'], 'Untitled'),
      subtitle: asStringOrNull(j['subtitle']),
      thumb: asStringOrNull(j['thumb']),
      isLive: asBool(j['isLive']),
      resumeAt: Duration(milliseconds: asInt(j['resumeAt'])),
      duration: Duration(milliseconds: asInt(j['duration'])),
      replay: replay is Map ? PlaybackRef.fromJson(replay.cast<String, dynamic>()) : null,
      updatedAt: asUnixMillis(j['updatedAt']) ?? DateTime.now(),
    );
  }
}

/// Download lifecycle. Same set as downloads.js, including `waiting`, which
/// means "yielded the provider connection to playback".
enum DownloadStatus { queued, waiting, downloading, paused, completed, failed }

class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.url,
    required this.title,
    required this.filePath,
    required this.status,
    this.subtitle = '',
    this.seriesName = '',
    this.thumb,
    this.isEpisode = false,
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.error = '',
    required this.addedAt,
    this.completedAt,
  });

  final String id;
  final String url;
  final String title;
  final String subtitle;
  final String seriesName;
  final String? thumb;
  final bool isEpisode;

  /// Final path. Bytes are written to "$filePath.part" until complete.
  final String filePath;

  final DownloadStatus status;
  final int totalBytes;
  final int receivedBytes;
  final String error;
  final DateTime addedAt;
  final DateTime? completedAt;

  String get partPath => '$filePath.part';

  double get progress {
    if (totalBytes > 0) {
      return (receivedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return status == DownloadStatus.completed ? 1 : 0;
  }

  int get remainingBytes =>
      totalBytes > 0 ? (totalBytes - receivedBytes).clamp(0, totalBytes) : 0;

  bool get isActive =>
      status == DownloadStatus.downloading ||
      status == DownloadStatus.queued ||
      status == DownloadStatus.waiting;

  DownloadItem copyWith({
    DownloadStatus? status,
    int? totalBytes,
    int? receivedBytes,
    String? error,
    String? filePath,
    DateTime? completedAt,
  }) =>
      DownloadItem(
        id: id,
        url: url,
        title: title,
        subtitle: subtitle,
        seriesName: seriesName,
        thumb: thumb,
        isEpisode: isEpisode,
        filePath: filePath ?? this.filePath,
        status: status ?? this.status,
        totalBytes: totalBytes ?? this.totalBytes,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        error: error ?? this.error,
        addedAt: addedAt,
        completedAt: completedAt ?? this.completedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'subtitle': subtitle,
        'seriesName': seriesName,
        'thumb': thumb,
        'isEpisode': isEpisode,
        'filePath': filePath,
        // Anything mid-flight when the app dies goes back in line as queued,
        // matching downloads.js's load().
        'status': (status == DownloadStatus.downloading ||
                status == DownloadStatus.waiting)
            ? DownloadStatus.queued.name
            : status.name,
        'totalBytes': totalBytes,
        'receivedBytes': receivedBytes,
        'error': error,
        'addedAt': addedAt.millisecondsSinceEpoch,
        'completedAt': completedAt?.millisecondsSinceEpoch,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        id: asString(j['id']),
        url: asString(j['url']),
        title: asString(j['title'], 'Video'),
        subtitle: asString(j['subtitle']),
        seriesName: asString(j['seriesName']),
        thumb: asStringOrNull(j['thumb']),
        isEpisode: asBool(j['isEpisode']),
        filePath: asString(j['filePath']),
        status: DownloadStatus.values.firstWhere(
          (s) => s.name == asString(j['status']),
          orElse: () => DownloadStatus.queued,
        ),
        totalBytes: asInt(j['totalBytes']),
        receivedBytes: asInt(j['receivedBytes']),
        error: asString(j['error']),
        addedAt: asUnixMillis(j['addedAt']) ?? DateTime.now(),
        completedAt: asUnixMillis(j['completedAt']),
      );
}
