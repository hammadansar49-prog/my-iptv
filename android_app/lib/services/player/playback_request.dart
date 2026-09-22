import '../../data/models/content.dart';
import '../../data/models/library.dart';

/// Everything the player needs to start, and everything history needs to
/// record it. Built by the repositories, never assembled ad hoc in a widget.
class PlaybackRequest {
  const PlaybackRequest({
    required this.url,
    required this.title,
    required this.isLive,
    required this.historyKey,
    this.subtitle = '',
    this.thumb,
    this.startAt = Duration.zero,
    this.replay,
    this.localFile,
    this.section = ContentSection.movies,
  });

  final String url;
  final String title;
  final String subtitle;
  final String? thumb;
  final bool isLive;

  /// Stable key for history/favorites. 'live:{id}', 'movie:{id}',
  /// 'episode:{id}' — matching the PC app.
  final String historyKey;

  /// Resume position. Passed INTO the open call, never applied as a seek
  /// afterwards (AUDIT.md §3 — the PC app's `startAt`/`_playDirect` rule).
  final Duration startAt;

  final PlaybackRef? replay;
  final ContentSection section;

  /// When set, this is played from disk and the network is never touched
  /// (spec §29).
  final String? localFile;

  bool get isLocal => localFile != null;

  /// What actually gets handed to the media engine.
  String get resolvedSource => localFile ?? url;

  PlaybackRequest copyWith({Duration? startAt}) => PlaybackRequest(
        url: url,
        title: title,
        subtitle: subtitle,
        thumb: thumb,
        isLive: isLive,
        historyKey: historyKey,
        startAt: startAt ?? this.startAt,
        replay: replay,
        localFile: localFile,
        section: section,
      );

  HistoryEntry toHistoryEntry() => HistoryEntry(
        key: historyKey,
        title: title,
        subtitle: subtitle.isEmpty ? null : subtitle,
        thumb: thumb,
        isLive: isLive,
        replay: replay,
        updatedAt: DateTime.now(),
      );
}
