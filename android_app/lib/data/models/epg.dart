import 'json.dart';

/// One programme in the guide.
///
/// The PC app has no EPG at all (AUDIT.md §7), so this is the one place the
/// Android app goes beyond it. Source is the standard Xtream
/// `get_short_epg` / `get_simple_data_table` response, whose title and
/// description arrive base64-encoded.
class EpgProgramme {
  const EpgProgramme({
    required this.id,
    required this.channelId,
    required this.title,
    required this.start,
    required this.end,
    this.description = '',
  });

  final String id;

  /// The panel's `epg_channel_id`, matching [LiveChannel.epgChannelId].
  final String channelId;

  final String title;
  final String description;
  final DateTime start;
  final DateTime end;

  Duration get duration {
    final d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  bool isLiveAt(DateTime now) => !now.isBefore(start) && now.isBefore(end);

  /// 0..1 through the programme. Computed locally and never polled from the
  /// server — spec §45 is explicit about this.
  double progressAt(DateTime now) {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final done = now.difference(start).inMilliseconds;
    if (done <= 0) return 0;
    if (done >= total) return 1;
    return done / total;
  }

  factory EpgProgramme.fromJson(Map<String, dynamic> j) {
    // Panels send either unix `start_timestamp`/`stop_timestamp` or the
    // formatted `start`/`end` strings. Prefer the timestamps.
    final start = asUnixSeconds(j['start_timestamp']) ??
        _parseLoose(asString(j['start'])) ??
        DateTime.now();
    final end = asUnixSeconds(j['stop_timestamp']) ??
        _parseLoose(asString(j['end'])) ??
        _parseLoose(asString(j['stop'])) ??
        start.add(const Duration(minutes: 30));

    return EpgProgramme(
      id: asString(j['id'], '${asString(j['epg_id'])}-${start.millisecondsSinceEpoch}'),
      channelId: asString(j['channel_id']),
      title: decodeEpgText(j['title']),
      description: decodeEpgText(j['description']),
      start: start,
      end: end.isAfter(start) ? end : start.add(const Duration(minutes: 30)),
    );
  }

  /// "2024-01-02 19:30:00" and similar. Panels report in their own timezone
  /// without an offset, so this parses as local time rather than inventing
  /// a UTC assumption that would shift the whole guide.
  static DateTime? _parseLoose(String raw) {
    if (raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim().replaceFirst(' ', 'T'));
  }
}

/// Now/next for one channel — exactly what the two-row EPG layout needs
/// (spec §12), so it is computed once and cached rather than re-scanned per
/// frame.
class ChannelGuide {
  const ChannelGuide({required this.channelKey, this.now, this.next});

  final String channelKey;
  final EpgProgramme? now;
  final EpgProgramme? next;

  bool get isEmpty => now == null && next == null;

  static const empty = ChannelGuide(channelKey: '');

  /// Pick now/next out of an ordered programme list.
  factory ChannelGuide.from(
    String channelKey,
    List<EpgProgramme> programmes,
    DateTime at,
  ) {
    EpgProgramme? current;
    EpgProgramme? upcoming;
    for (final p in programmes) {
      if (p.isLiveAt(at)) {
        current = p;
      } else if (p.start.isAfter(at)) {
        if (upcoming == null || p.start.isBefore(upcoming.start)) upcoming = p;
      }
    }
    return ChannelGuide(channelKey: channelKey, now: current, next: upcoming);
  }
}
