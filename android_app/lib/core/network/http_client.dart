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

  Future<String> getText(String url, {CancelToken? cancel}) async {
    try {
      final res = await _dio.get<String>(url, cancelToken: cancel);
      final status = res.statusCode ?? 0;
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
    } on AppError {
      rethrow;
    } on DioException catch (e) {
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
    }
  }

  /// A cheap reachability/validity probe used before handing a URL to the
  /// player (spec §24). It is a HEAD, so it does not open a streaming
  /// connection — but it still costs a provider socket, so it is only ever
  /// called from inside the connection guard.
  Future<MediaProbe> probeMedia(String url, {CancelToken? cancel}) async {
    try {
      final res = await _dio.head<void>(
        url,
        cancelToken: cancel,
        options: Options(
          headers: {'User-Agent': Api.downloadUserAgent},
          followRedirects: true,
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final status = res.statusCode ?? 0;
      final type = (res.headers.value('content-type') ?? '').toLowerCase();
      final length = int.tryParse(res.headers.value('content-length') ?? '');
      return MediaProbe(status: status, contentType: type, contentLength: length);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      return MediaProbe(status: 0, contentType: '', contentLength: null, error: e.message);
    }
  }

  void close() => _dio.close(force: true);
}

/// Result of [HttpClient.probeMedia].
class MediaProbe {
  const MediaProbe({
    required this.status,
    required this.contentType,
    required this.contentLength,
    this.error,
  });

  final int status;
  final String contentType;
  final int? contentLength;
  final String? error;

  /// Content types that mean "this is not video" — the exact failure mode
  /// spec §24 was written about (raw HTML ending up in the player).
  static const _notMedia = ['text/html', 'application/json', 'text/plain', 'text/xml'];

  bool get looksPlayable {
    if (status == 0) return false;
    // Many panels answer HEAD with 405 or 501 but stream fine on GET; only a
    // definite auth/not-found answer counts as a refusal.
    if (status == 401 || status == 403 || status == 404 || status == 410) return false;
    if (_notMedia.any(contentType.startsWith)) return false;
    return true;
  }
}
