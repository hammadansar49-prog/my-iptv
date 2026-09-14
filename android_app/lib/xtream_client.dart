import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class XtreamException implements Exception {
  final String message;
  XtreamException(this.message);
  @override
  String toString() => message;
}

class XtreamClient {
  final String baseUrl;
  final String username;
  final String password;

  XtreamClient({required String baseUrl, required this.username, required this.password})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  Uri _api(String action, [Map<String, String>? extra]) {
    final params = {
      'username': username,
      'password': password,
      if (action.isNotEmpty) 'action': action,
      ...?extra,
    };
    return Uri.parse('$baseUrl/player_api.php').replace(queryParameters: params);
  }

  Future<dynamic> _get(Uri uri) async {
    http.Response res;
    try {
      res = await http.get(uri, headers: {'User-Agent': 'IPTVPlayer/1.0'}).timeout(
        const Duration(seconds: 45),
      );
    } catch (e) {
      throw XtreamException('Network error — please check your connection.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw XtreamException('Server returned HTTP ${res.statusCode}');
    }
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (e) {
      throw XtreamException('Server sent an invalid response.');
    }
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

  Future<List<Category>> _categories(String action) async {
    final data = await _get(_api(action));
    if (data is! List) return [];
    return data.map((e) => Category.fromJson(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<Category>> getLiveCategories() => _categories('get_live_categories');
  Future<List<Category>> getVodCategories() => _categories('get_vod_categories');
  Future<List<Category>> getSeriesCategories() => _categories('get_series_categories');

  Future<List<PlayableItem>> getLiveStreams(String? categoryId) async {
    final data = await _get(_api('get_live_streams', categoryId != null ? {'category_id': categoryId} : null));
    if (data is! List) return [];
    return data.map((e) => PlayableItem.fromLive(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<PlayableItem>> getVodStreams(String? categoryId) async {
    final data = await _get(_api('get_vod_streams', categoryId != null ? {'category_id': categoryId} : null));
    if (data is! List) return [];
    return data.map((e) => PlayableItem.fromVod(Map<String, dynamic>.from(e))).toList();
  }

  Future<List<PlayableItem>> getSeries(String? categoryId) async {
    final data = await _get(_api('get_series', categoryId != null ? {'category_id': categoryId} : null));
    if (data is! List) return [];
    return data.map((e) => PlayableItem.fromSeries(Map<String, dynamic>.from(e))).toList();
  }

  Future<Map<String, dynamic>?> getSeriesInfo(String seriesId) async {
    final data = await _get(_api('get_series_info', {'series_id': seriesId}));
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data);
  }

  String liveUrl(String streamId, {String ext = 'm3u8'}) =>
      '$baseUrl/live/$username/$password/$streamId.$ext';
  String vodUrl(String streamId, {String ext = 'mp4'}) =>
      '$baseUrl/movie/$username/$password/$streamId.$ext';
  String seriesEpisodeUrl(String episodeId, {String ext = 'mp4'}) =>
      '$baseUrl/series/$username/$password/$episodeId.$ext';
}
