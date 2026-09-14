import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;
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

  /// Where full lists are kept between launches (see [_cachedBytes]).
  final Directory? cacheDir;

  XtreamClient({required String baseUrl, required this.username, required this.password, this.cacheDir})
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

  Future<Uint8List> _getBytes(Uri uri, {Duration timeout = const Duration(seconds: 60)}) async {
    http.Response res;
    try {
      res = await http.get(uri, headers: {'User-Agent': 'IPTVPlayer/1.0', 'Accept-Encoding': 'gzip'}).timeout(timeout);
    } catch (e) {
      throw XtreamException('Network error — please check your connection.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw XtreamException('Server returned HTTP ${res.statusCode}');
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
  File? _cacheFile(String key) {
    final dir = cacheDir;
    if (dir == null) return null;
    final safe = '${baseUrl.hashCode}_${username.hashCode}_$key'.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return File('${dir.path}/catalog_$safe.json');
  }

  Future<Uint8List> _cachedBytes(String key, Uri uri, {bool force = false}) async {
    final file = _cacheFile(key);
    if (file != null && !force) {
      try {
        if (await file.exists()) {
          final age = DateTime.now().difference(await file.lastModified());
          if (age < _catalogTtl) return await file.readAsBytes();
        }
      } catch (_) {/* fall through to the network */}
    }
    final bytes = await _getBytes(uri);
    if (file != null && bytes.length > 2) {
      file.writeAsBytes(bytes, flush: false).catchError((_) => file);
    }
    return bytes;
  }

  Future<void> clearCatalogCache() async {
    final dir = cacheDir;
    if (dir == null) return;
    try {
      await for (final f in dir.list()) {
        if (f is File && f.path.contains('catalog_')) await f.delete();
      }
    } catch (_) {}
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
    final data = await _get(_api('get_series_info', {'series_id': seriesId}));
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data);
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
