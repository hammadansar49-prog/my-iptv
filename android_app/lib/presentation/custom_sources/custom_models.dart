import '../../data/models/content.dart';

/// Models + the M3U parser for the user-added sources (Single Channel and
/// M3U Playlist). Deliberately separate from the Xtream models: nothing here
/// touches the Xtream catalogue, and nothing in the Xtream flow knows these
/// exist.

/// File extensions that are on-demand files (seekable, finite). Anything
/// else — .m3u8, .ts, rtmp/rtsp, or a bare path with no extension, which is
/// how most IPTV live links look — is treated as live.
const _vodExtensions = {
  'mp4', 'mkv', 'avi', 'mov', 'm4v', 'webm', 'flv', 'wmv', 'mpg', 'mpeg',
  '3gp', 'mp3', 'aac', 'm4a', 'flac', 'ogg', 'wav',
};

bool isLiveUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return true;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'rtmp' || scheme == 'rtsp' || scheme == 'rtmps') return true;
  final path = uri.path;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/')) return true;
  return !_vodExtensions.contains(path.substring(dot + 1).toLowerCase());
}

ContentSection sectionForUrl(String url) =>
    isLiveUrl(url) ? ContentSection.live : ContentSection.movies;

/// A stream URL the player can open. rtmp/rtsp are allowed for single
/// channels because libmpv plays them directly.
bool isValidStreamUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return false;
  return const {'http', 'https', 'rtmp', 'rtmps', 'rtsp'}
      .contains(uri.scheme.toLowerCase());
}

/// Playlists are downloaded with Dio, so only http(s).
bool isValidPlaylistUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.host.isEmpty) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}

class CustomChannel {
  const CustomChannel({
    required this.id,
    required this.name,
    required this.url,
    this.logo,
  });

  final String id;
  final String name;
  final String url;
  final String? logo;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (logo != null) 'logo': logo,
      };

  static CustomChannel? fromJson(Map<String, dynamic> j) {
    final id = j['id'], name = j['name'], url = j['url'];
    if (id is! String || name is! String || url is! String) return null;
    final logo = j['logo'];
    return CustomChannel(
      id: id,
      name: name,
      url: url,
      logo: logo is String && logo.isNotEmpty ? logo : null,
    );
  }
}

/// Only the metadata lives in LocalStore; the raw playlist text (which can
/// be tens of MB) is a separate file — see `CustomSourcesStore`.
class M3uPlaylist {
  const M3uPlaylist({
    required this.id,
    required this.name,
    required this.url,
    this.lastRefresh,
    this.entryCount = 0,
  });

  final String id;
  final String name;
  final String url;
  final DateTime? lastRefresh;
  final int entryCount;

  M3uPlaylist copyWith({String? name, DateTime? lastRefresh, int? entryCount}) =>
      M3uPlaylist(
        id: id,
        name: name ?? this.name,
        url: url,
        lastRefresh: lastRefresh ?? this.lastRefresh,
        entryCount: entryCount ?? this.entryCount,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (lastRefresh != null)
          'lastRefresh': lastRefresh!.millisecondsSinceEpoch,
        'entryCount': entryCount,
      };

  static M3uPlaylist? fromJson(Map<String, dynamic> j) {
    final id = j['id'], name = j['name'], url = j['url'];
    if (id is! String || name is! String || url is! String) return null;
    final lr = j['lastRefresh'];
    final count = j['entryCount'];
    return M3uPlaylist(
      id: id,
      name: name,
      url: url,
      lastRefresh:
          lr is int ? DateTime.fromMillisecondsSinceEpoch(lr) : null,
      entryCount: count is int ? count : 0,
    );
  }
}

class M3uEntry {
  M3uEntry({
    required this.name,
    required this.url,
    this.logo,
    this.group,
    this.tvgId,
    this.duration = -1,
    this.userAgent,
    this.referrer,
  }) : searchKey = name.toLowerCase();

  final String name;
  final String url;
  final String? logo;
  final String? group;
  final String? tvgId;
  final int duration;

  /// Kept from `#EXTVLCOPT` for completeness. `PlaybackRequest` has no
  /// headers field and the player always sends the app's own User-Agent,
  /// so these are not applied at playback time (changing the player was
  /// out of scope).
  final String? userAgent;
  final String? referrer;

  /// Lower-cased once at parse time so filtering 20k+ rows on every
  /// keystroke doesn't re-lowercase every name.
  final String searchKey;
}

final _attr = RegExp(r'([\w-]+)="([^"]*)"');

/// Parses `#EXTM3U` text. Top-level so it can run in `compute()`.
///
/// Tolerant by design: real-world playlists have missing headers, CRLF
/// endings, BOMs, and commas inside quoted attributes, so the display name
/// is taken after the first comma that is *outside* quotes.
List<M3uEntry> parseM3u(String text) {
  final out = <M3uEntry>[];
  String? name, logo, group, tvgId, extGrp, ua, ref;
  var duration = -1;
  var pending = false;

  void reset() {
    name = logo = group = tvgId = ua = ref = null;
    duration = -1;
    pending = false;
  }

  for (var raw in text.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    if (line.codeUnitAt(0) == 0xFEFF) line = line.substring(1);

    if (line.startsWith('#EXTINF:')) {
      reset();
      pending = true;
      final body = line.substring(8);
      var inQuote = false, comma = -1;
      for (var i = 0; i < body.length; i++) {
        final c = body[i];
        if (c == '"') {
          inQuote = !inQuote;
        } else if (c == ',' && !inQuote) {
          comma = i;
          break;
        }
      }
      final head = comma < 0 ? body : body.substring(0, comma);
      final title = comma < 0 ? '' : body.substring(comma + 1).trim();
      final sp = head.indexOf(' ');
      duration = int.tryParse((sp < 0 ? head : head.substring(0, sp)).trim()) ?? -1;
      String? tvgName;
      for (final m in _attr.allMatches(head)) {
        final v = m.group(2)!.trim();
        if (v.isEmpty) continue;
        switch (m.group(1)!.toLowerCase()) {
          case 'tvg-name':
            tvgName = v;
          case 'tvg-logo':
            logo = v;
          case 'group-title':
            group = v;
          case 'tvg-id':
            tvgId = v;
        }
      }
      name = title.isNotEmpty ? title : tvgName;
    } else if (line.startsWith('#EXTGRP:')) {
      extGrp = line.substring(8).trim();
    } else if (line.startsWith('#EXTVLCOPT:')) {
      final opt = line.substring(11);
      final eq = opt.indexOf('=');
      if (eq > 0) {
        final k = opt.substring(0, eq).trim().toLowerCase();
        final v = opt.substring(eq + 1).trim();
        if (k == 'http-user-agent') ua = v;
        if (k == 'http-referrer' || k == 'http-referer') ref = v;
      }
    } else if (line.startsWith('#')) {
      // #EXTM3U and any unknown directive.
      continue;
    } else {
      // A URL line. Entries without a preceding #EXTINF (plain URL lists)
      // are still playable, named after the URL.
      final g = group ?? ((extGrp?.isNotEmpty ?? false) ? extGrp : null);
      out.add(M3uEntry(
        name: (name?.isNotEmpty ?? false) ? name! : line,
        url: line,
        logo: logo,
        group: g,
        tvgId: tvgId,
        duration: pending ? duration : -1,
        userAgent: ua,
        referrer: ref,
      ));
      reset();
      extGrp = null;
    }
  }
  return out;
}
