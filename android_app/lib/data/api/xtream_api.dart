import 'package:dio/dio.dart';

import '../../core/errors/app_error.dart';
import '../../core/network/http_client.dart';
import '../models/account.dart';
import '../models/content.dart';
import '../models/epg.dart';
import '../models/json.dart';

/// Xtream Codes client. A direct port of `src/xtream.js`, including its
/// validation rules — see AUDIT.md §2. Do not add endpoints that the PC app
/// does not use without checking the panel actually supports them; the one
/// deliberate addition is EPG, which the PC app never implemented.
class XtreamApi {
  XtreamApi({required this.account, required HttpClient http}) : _http = http;

  final Account account;
  final HttpClient _http;

  String get _base => account.url;

  /// `{base}/player_api.php?username=&password=[&action=][extra]`
  String _api(String action, [String extra = '']) {
    final u = Uri.encodeQueryComponent(account.username);
    final p = Uri.encodeQueryComponent(account.password);
    final a = action.isEmpty ? '' : '&action=$action';
    return '$_base/player_api.php?username=$u&password=$p$a$extra';
  }

  // ---- Auth ---------------------------------------------------------------

  /// Reproduces `authenticate()` exactly:
  ///  1. no `user_info` -> invalid response
  ///  2. `auth` 0 or '0' -> bad credentials
  ///  3. `status` present and not 'Active' -> report the status
  Future<XtreamSession> authenticate({CancelToken? cancel}) async {
    final data = await _http.getJson(_api(''), cancel: cancel);
    if (data is! Map) {
      throw const AppError(
        AppErrorKind.authentication,
        'Invalid credentials — please check your Server URL, Username and Password and try again.',
        detail: 'response was not a JSON object',
      );
    }
    final map = data.cast<String, dynamic>();
    final rawUser = map['user_info'];
    if (rawUser is! Map) {
      throw const AppError(
        AppErrorKind.authentication,
        'Invalid credentials — please check your Server URL, Username and Password and try again.',
        detail: 'no user_info in response',
      );
    }

    final userInfo = XtreamUserInfo.fromJson(rawUser.cast<String, dynamic>());
    if (!userInfo.isAuthenticated) throw AppError.badCredentials;

    if (!userInfo.isActive) {
      throw AppError(
        AppErrorKind.subscription,
        'Account status: ${userInfo.status}',
        detail: 'panel reported status=${userInfo.status}',
      );
    }

    return XtreamSession(
      userInfo: userInfo,
      serverInfo: XtreamServerInfo.fromJson(asMap(map['server_info'])),
    );
  }

  // ---- Catalogue ----------------------------------------------------------

  Future<List<Category>> liveCategories({CancelToken? cancel}) async =>
      _categories('get_live_categories', cancel);

  Future<List<Category>> vodCategories({CancelToken? cancel}) async =>
      _categories('get_vod_categories', cancel);

  Future<List<Category>> seriesCategories({CancelToken? cancel}) async =>
      _categories('get_series_categories', cancel);

  Future<List<Category>> _categories(String action, CancelToken? cancel) async {
    final data = await _http.getJson(_api(action), cancel: cancel);
    return asMapList(data).map(Category.fromJson).toList();
  }

  Future<List<LiveChannel>> liveStreams({
    String? categoryId,
    CancelToken? cancel,
  }) async {
    final data = await _http.getJson(
      _api('get_live_streams', _categoryParam(categoryId)),
      cancel: cancel,
    );
    return asMapList(data).map(LiveChannel.fromJson).toList();
  }

  Future<List<Movie>> vodStreams({String? categoryId, CancelToken? cancel}) async {
    final data = await _http.getJson(
      _api('get_vod_streams', _categoryParam(categoryId)),
      cancel: cancel,
    );
    return asMapList(data).map(Movie.fromJson).toList();
  }

  Future<List<Series>> series({String? categoryId, CancelToken? cancel}) async {
    final data = await _http.getJson(
      _api('get_series', _categoryParam(categoryId)),
      cancel: cancel,
    );
    return asMapList(data).map(Series.fromJson).toList();
  }

  Future<MovieDetail?> vodInfo(Movie base, {CancelToken? cancel}) async {
    final data = await _http.getJson(
      _api('get_vod_info', '&vod_id=${base.streamId}'),
      cancel: cancel,
    );
    if (data is! Map) return null;
    return MovieDetail.fromJson(base, data.cast<String, dynamic>());
  }

  Future<SeriesDetail?> seriesInfo(Series base, {CancelToken? cancel}) async {
    final data = await _http.getJson(
      _api('get_series_info', '&series_id=${base.seriesId}'),
      cancel: cancel,
    );
    if (data is! Map) return null;
    return SeriesDetail.fromJson(base, data.cast<String, dynamic>());
  }

  String _categoryParam(String? categoryId) =>
      (categoryId == null || categoryId.isEmpty)
          ? ''
          : '&category_id=${Uri.encodeQueryComponent(categoryId)}';

  // ---- EPG ----------------------------------------------------------------
  //
  // Not present in the PC app (AUDIT.md §7). Standard Xtream endpoints on the
  // same player_api.php base. A panel with no guide data answers with an
  // empty list, which must degrade to the PC app's "no programme guide data
  // from this provider" state rather than an error.

  /// Now/next for one channel. `limit` keeps the response small — the
  /// two-row layout only needs a couple of entries.
  Future<List<EpgProgramme>> shortEpg(
    int streamId, {
    int limit = 4,
    CancelToken? cancel,
  }) async {
    try {
      final data = await _http.getJson(
        _api('get_short_epg', '&stream_id=$streamId&limit=$limit'),
        cancel: cancel,
      );
      return _parseEpg(data);
    } on AppError catch (e) {
      // A panel without EPG support may answer with something unparseable.
      // That is "no guide", not a failure the user should see.
      if (e.kind == AppErrorKind.parsing) return const [];
      rethrow;
    }
  }

  /// Fuller listing for the day view.
  Future<List<EpgProgramme>> fullEpg(int streamId, {CancelToken? cancel}) async {
    try {
      final data = await _http.getJson(
        _api('get_simple_data_table', '&stream_id=$streamId'),
        cancel: cancel,
      );
      return _parseEpg(data);
    } on AppError catch (e) {
      if (e.kind == AppErrorKind.parsing) return const [];
      rethrow;
    }
  }

  List<EpgProgramme> _parseEpg(Object? data) {
    // Both endpoints wrap the rows in `epg_listings`; some panels return a
    // bare array instead.
    final rows = data is Map
        ? asMapList(data.cast<String, dynamic>()['epg_listings'])
        : asMapList(data);
    final out = rows.map(EpgProgramme.fromJson).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  // ---- Stream URLs --------------------------------------------------------

  String liveStreamUrl(int streamId, {String ext = 'm3u8'}) =>
      '$_base/live/${_credPath()}/$streamId.$ext';

  String movieStreamUrl(int streamId, {String ext = 'mp4'}) =>
      '$_base/movie/${_credPath()}/$streamId.$ext';

  String episodeStreamUrl(String episodeId, {String ext = 'mp4'}) =>
      '$_base/series/${_credPath()}/$episodeId.$ext';

  String _credPath() =>
      '${Uri.encodeComponent(account.username)}/${Uri.encodeComponent(account.password)}';
}
