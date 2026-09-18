import 'dart:convert';
import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;
import 'cache_manager.dart';
import 'models.dart';

class XtreamException implements Exception {
  final String message;
  XtreamException(this.message);
  @override
  String toString() => message;
}

// ---- Parsing, done on a background isolate ----
//
// The full movie list is ~27 MB of JSON (tens of thousands of entries).
// Decoding and mapping that on the UI isolate froze the app for seconds —
// long enough for Android to offer to close it.

dynamic _decodeBytes(Uint8List bytes) => jsonDecode(utf8.decode(bytes, allowMalformed: true));

List<PlayableItem> _parseItems(_ParseJob job) {
  final data = _decodeBytes(job.bytes);
  if (data is! List) return const [];
  final out = <PlayableItem>[];
  for (final e in data) {
    if (e is! Map) continue;
    final m = Map<String, dynamic>.from(e);
    switch (job.kind) {
      case 'live':
        out.add(PlayableItem.fromLive(m));
        break;
      case 'movies':
        out.add(PlayableItem.fromVod(m));
        break;
      default:
        out.add(PlayableItem.fromSeries(m));
    }
  }
  return out;
}

class _ParseJob {
  final Uint8List bytes;
  final String kind;
  _ParseJob(this.bytes, this.kind);
}

List<Category> _parseCategories(Uint8List bytes) {
  final data = _decodeBytes(bytes);
  if (data is! List) return const [];
  return data.whereType<Map>().map((e) => Category.fromJson(Map<String, dynamic>.from(e))).toList();
}

class XtreamClient {
  final String baseUrl;
  final String username;
  final String password;

  /// Persistent disk cache for catalog JSON blobs (see [_cachedBytes]).
  final DiskCache? diskCache;

  /// In-flight requests to prevent concurrent network calls for the same key.
  /// Keyed by `baseUrl_username_action` so two different accounts don't share
  /// a pending request (which would cause account A's data to be served to B).
  static final Map<String, Future<Uint8List>> _pendingRequests = {};

  /// In-memory cache for series info (series_id -> parsed data). Avoids a
  /// network round-trip every time the user taps the same series twice.
  final Map<String, Map<String, dynamic>> _seriesInfoCache = {};

  XtreamClient({required String baseUrl, required this.username, required this.password, this.diskCache})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  static const _catalogTtl = Duration(minutes: 10);

  Uri _api(String action, [Map<String, String>? extra]) {
    final params = {
      'username': username,
      'password': password,
      if (action.isNotEmpty) 'action': action,
      ...?extra,
    };
    return Uri.parse('$baseUrl/player_api.php').replace(queryParameters: params);
  }

  Future<Uint8List> _getBytes(Uri uri, {Duration timeout = const Duration(seconds: 15)}) async {
    http.Response res;
    try {
      res = await http.get(uri, headers: {'User-Agent': 'IPTVPlayer/1.0', 'Accept-Encoding': 'gzip'}).timeout(timeout);
    } catch (e) {
      throw XtreamException('Network error — please check your connection.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw XtreamException('Server returned HTTP ${res.statusCode}');
    }
    // Proxies, captive portals and expired URLs commonly return a 200 OK
    // with text/html (a login page, an error page, etc.) instead of the
    // expected JSON or binary stream. Passing that straight to the player
    // or JSON decoder produced garbled HTML text on screen or a blank
    // player — detect it early and throw a clear, user-facing error.
    final contentType = res.headers['content-type'] ?? '';
    if (contentType.contains('text/html') || contentType.contains('text/plain')) {
      final snippet = String.fromCharCodes(res.bodyBytes.take(128));
      if (snippet.toLowerCase().contains('<!doctype') || snippet.toLowerCase().contains('<html')) {
        throw XtreamException('Server returned an error page instead of data. The URL may have expired or the server is misconfigured.');
      }
    }
    return res.bodyBytes;
  }

  Future<dynamic> _get(Uri uri) async {
    final bytes = await _getBytes(uri);
    try {
      return await compute(_decodeBytes, bytes);
    } catch (e) {
      throw XtreamException('Server sent an invalid response.');
    }
  }

  // A list fetched within the last few minutes is read back from disk:
  // relaunching the app, or coming back to it, doesn't download the whole
  // catalog again. An empty or failed answer is never stored — serving that
  // later is how a section ended up showing "0 items".
  String _cacheKey(String key) => '${baseUrl.hashCode}_${username.hashCode}_$key';

  /// Pending-request key scoped to this client instance so two accounts
  /// fetching the same action simultaneously don't share an in-flight Future.
  String _pendingKey(String action) => '${baseUrl}_${username}_$action';

  Future<Uint8List> _cachedBytes(String key, Uri uri, {bool force = false}) async {
    if (diskCache != null && !force) {
      try {
        final cached = await diskCache!.get(_cacheKey(key), ttl: _catalogTtl);
        if (cached != null && cached.length > 2) return cached;
      } catch (_) {/* fall through to the network */}
    }
    // Return existing in-flight request if one is already running for this key
    final pk = _pendingKey(key);
    if (_pendingRequests.containsKey(pk)) return _pendingRequests[pk]!;
    final future = _getBytes(uri).then((bytes) {
      _pendingRequests.remove(pk);
      if (diskCache != null && bytes.length > 2) {
        diskCache!.put(_cacheKey(key), bytes);
      }
      return bytes;
    }).catchError((e, st) {
      _pendingRequests.remove(pk);
      return Future<Uint8List>.error(e, st);
    });
    _pendingRequests[pk] = future;
    return future;
  }

  Future<void> clearCatalogCache() async {
    _seriesInfoCache.clear();
    await diskCache?.clear();
  }

  Future<Map<String, dynamic>> authenticate() async {
    final data = await _get(_api(''));
    if (data is! Map || data['user_info'] == null) {
      throw XtreamException('Invalid response from server.');
    }
    final info = data['user_info'];
    if ('${info['auth']}' == '0') {
      throw XtreamException('Invalid username or password.');
    }
    if (info['status'] != null && info['status'] != 'Active') {
      throw XtreamException('Account status: ${info['status']}');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<List<Category>> _categories(String action, {bool force = false}) async {
    final bytes = await _cachedBytes(action, _api(action), force: force);
    return compute(_parseCategories, bytes);
  }

  Future<List<Category>> getLiveCategories({bool force = false}) => _categories('get_live_categories', force: force);
  Future<List<Category>> getVodCategories({bool force = false}) => _categories('get_vod_categories', force: force);
  Future<List<Category>> getSeriesCategories({bool force = false}) => _categories('get_series_categories', force: force);

  Future<List<PlayableItem>> _items(String action, String kind, String? categoryId, {bool force = false}) async {
    final uri = _api(action, categoryId != null ? {'category_id': categoryId} : null);
    final bytes = categoryId == null
        ? await _cachedBytes(action, uri, force: force)
        : await _getBytes(uri);
    try {
      return await compute(_parseItems, _ParseJob(bytes, kind));
    } catch (_) {
      throw XtreamException('Server sent an invalid response.');
    }
  }

  Future<List<PlayableItem>> getLiveStreams(String? categoryId, {bool force = false}) =>
      _items('get_live_streams', 'live', categoryId, force: force);
  Future<List<PlayableItem>> getVodStreams(String? categoryId, {bool force = false}) =>
      _items('get_vod_streams', 'movies', categoryId, force: force);
  Future<List<PlayableItem>> getSeries(String? categoryId, {bool force = false}) =>
      _items('get_series', 'series', categoryId, force: force);

  Future<Map<String, dynamic>?> getSeriesInfo(String seriesId) async {
    final cached = _seriesInfoCache[seriesId];
    if (cached != null) return cached;
    final data = await _get(_api('get_series_info', {'series_id': seriesId}));
    if (data is! Map) return null;
    final result = Map<String, dynamic>.from(data);
    _seriesInfoCache[seriesId] = result;
    return result;
  }

  /// Now / next programme for one channel. Titles arrive base64-encoded.
  Future<List<EpgEntry>> getShortEpg(String streamId, {int limit = 3}) async {
    final data = await _get(_api('get_short_epg', {'stream_id': streamId, 'limit': '$limit'}));
    final list = data is Map ? data['epg_listings'] : null;
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => EpgEntry.fromJson(Map<String, dynamic>.from(e))).where((e) => e.stop > e.start).toList();
  }

  String liveUrl(String streamId, {String ext = 'm3u8'}) =>
      '$baseUrl/live/$username/$password/$streamId.$ext';
  String vodUrl(String streamId, {String ext = 'mp4'}) =>
      '$baseUrl/movie/$username/$password/$streamId.$ext';
  String seriesEpisodeUrl(String episodeId, {String ext = 'mp4'}) =>
      '$baseUrl/series/$username/$password/$episodeId.$ext';
}
