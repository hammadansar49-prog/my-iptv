/// Centralised error model (spec §49). Every layer converts whatever it
/// caught into one of these; widgets only ever read [message], never a stack
/// trace, and never the raw server body.
enum AppErrorKind {
  network,
  authentication,
  subscription,
  server,
  playback,
  download,
  parsing,
  storage,
  unknown,
}

class AppError implements Exception {
  const AppError(
    this.kind,
    this.message, {
    this.detail,
    this.cause,
    this.retryable = false,
  });

  final AppErrorKind kind;

  /// Short, plain, user-facing. No jargon, no stack traces.
  final String message;

  /// Developer-only context. Logged, never shown.
  final String? detail;

  final Object? cause;
  final bool retryable;

  AppError copyWith({String? message, bool? retryable}) => AppError(
        kind,
        message ?? this.message,
        detail: detail,
        cause: cause,
        retryable: retryable ?? this.retryable,
      );

  @override
  String toString() => 'AppError(${kind.name}: $message${detail == null ? '' : ' | $detail'})';

  // ---- Common constructors -------------------------------------------------

  static const noInternet = AppError(
    AppErrorKind.network,
    'No internet connection.',
    retryable: true,
  );

  static const timeout = AppError(
    AppErrorKind.network,
    'Could not reach the server — check your internet connection, the server may be down.',
    retryable: true,
  );

  static const badCredentials = AppError(
    AppErrorKind.authentication,
    'Invalid credentials — please check your Server URL, Username and Password and try again.',
  );

  /// The device itself has no network (Wi-Fi/ethernet/mobile all off).
  /// Checked before blaming the server: offline, a DNS lookup fails and
  /// used to read "Server address not found — check the Server URL".
  static const offline = AppError(
    AppErrorKind.network,
    'No internet connection — please check your Wi-Fi or network and try again.',
    retryable: true,
  );

  static const unplayable = AppError(
    AppErrorKind.playback,
    'Unable to play this stream.',
    retryable: true,
  );

  /// Mirrors `friendlyAuthError` in the PC app's src/renderer.js so the two
  /// apps say the same thing about the same failure (AUDIT.md §2).
  static AppError fromTransport(Object error, {String? detail}) {
    final raw = error.toString();
    if (RegExp(r'ENOTFOUND|getaddrinfo|Failed host lookup|nodename nor servname',
            caseSensitive: false)
        .hasMatch(raw)) {
      return AppError(
        AppErrorKind.network,
        'Server address not found — please check the Server URL.',
        detail: detail ?? raw,
        retryable: false,
      );
    }
    if (RegExp(r'ECONNREFUSED|Connection refused', caseSensitive: false).hasMatch(raw)) {
      return AppError(
        AppErrorKind.network,
        'Connection refused by the server.',
        detail: detail ?? raw,
        retryable: true,
      );
    }
    if (RegExp(r'ETIMEDOUT|timeout|timed out', caseSensitive: false).hasMatch(raw)) {
      return timeout.copyWith();
    }
    return AppError(
      AppErrorKind.network,
      'Could not reach the server.',
      detail: detail ?? raw,
      cause: error,
      retryable: true,
    );
  }
}
