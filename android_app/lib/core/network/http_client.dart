import 'dart:convert';

import 'package:dio/dio.dart';

import '../constants/app_constants.dart';
import '../errors/app_error.dart';
import '../utils/logger.dart';

/// Thin wrapper over Dio configured the way the PC app's `fetchText` was:
/// same user agent, same redirect limit, same generous read timeout, same
/// response size cap, and the same "a body that isn't JSON is a server
/// problem, not a crash" behaviour.
class HttpClient {
  HttpClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: Api.connectTimeout,
              receiveTimeout: Api.metadataTimeout,
              sendTimeout: Api.connectTimeout,
              maxRedirects: Api.maxRedirects,
              followRedirects: true,
              // We validate ourselves so a 4xx/5xx body can be inspected
              // instead of throwing an opaque DioException.
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
              headers: {
                'User-Agent': Api.metadataUserAgent,
                'Accept-Encoding': 'gzip, deflate',
              },
            ));

  final Dio _dio;

  /// GET a JSON document. Returns `null` for an empty/`null` body — the PC
  /// app treats that as "no rows", not as an error (AUDIT.md §2).
  ///
  /// For auth/categories/EPG only — small, fixed-shape responses. The three
  /// catalogue endpoints that can run tens of megabytes (get_live_streams,
  /// get_vod_streams, get_series) do NOT go through this: see
  /// `XtreamApi._decodeAndMap` for why decoding *and* model-mapping have to
  /// happen together in one background-isolate `compute()` call for those,
  /// instead of handing back a giant raw decoded structure from here.
  Future<Object?> getJson(String url, {CancelToken? cancel}) async {
    final text = await getText(url, cancel: cancel);
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed == 'null') return null;
    try {
      return jsonDecode(trimmed);
    } on FormatException catch (e) {
      // This is the case spec §24 is about: an HTML login page or an error
      // page where JSON was expected. Never surface the body.
      throw AppError(
        AppErrorKind.parsing,
        'Server sent an invalid response.',
        detail: '${e.message} | head=${trimmed.substring(0, trimmed.length.clamp(0, 200))}',
      );
    }
  }

  /// [onProgress] receives Dio's raw receive progress. `total` is -1 when
  /// the panel sends no Content-Length — the usual case here, because the
  /// body is gzipped and decompressed on the fly — so callers must be able
  /// to work from `received` alone.
  Future<String> getText(
    String url, {
    CancelToken? cancel,
    void Function(int received, int total)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    Log.i('HttpClient', '-> GET ${Log.redact(url)}');
    try {
      final res = await _dio.get<String>(
        url,
        cancelToken: cancel,
        onReceiveProgress: onProgress,
      );
      final status = res.statusCode ?? 0;
      Log.i('HttpClient',
          '<- $status (${sw.elapsedMilliseconds}ms, ${res.data?.length ?? 0} bytes) ${Log.redact(url)}');
      if (status < 200 || status >= 300) {
        throw AppError(
          status == 401 || status == 403
              ? AppErrorKind.authentication
              : AppErrorKind.server,
          status == 401 || status == 403
              ? 'Invalid credentials — please check your Server URL, Username and Password and try again.'
              : 'The server is not responding correctly.',
          detail: 'HTTP $status for ${Log.redact(url)}',
          retryable: status >= 500,
        );
      }
      final body = res.data ?? '';
      if (body.length > Api.maxResponseBytes) {
        throw const AppError(AppErrorKind.server, 'The server sent too much data.');
      }
      return body;
    } on AppError catch (e) {
      Log.e('HttpClient',
          'AppError after ${sw.elapsedMilliseconds}ms for ${Log.redact(url)}: ${e.kind} ${e.message}');
      rethrow;
    } on DioException catch (e) {
      Log.e('HttpClient',
          'DioException(${e.type}) after ${sw.elapsedMilliseconds}ms for ${Log.redact(url)}: ${e.message}');
      if (CancelToken.isCancel(e)) rethrow;
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          throw AppError.timeout.copyWith();
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
          throw AppError.fromTransport(e.error ?? e, detail: e.message);
        default:
          throw AppError(
            AppErrorKind.network,
            'Could not reach the server.',
            detail: e.message,
            cause: e,
            retryable: true,
          );
      }
    } catch (e, st) {
      Log.e('HttpClient',
          'Unexpected ${e.runtimeType} after ${sw.elapsedMilliseconds}ms for ${Log.redact(url)}: $e',
          e, st);
      rethrow;
    }
  }

  void close() => _dio.close(force: true);
}
