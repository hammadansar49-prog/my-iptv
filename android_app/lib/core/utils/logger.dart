import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Structured logging (spec §50). Silent in release builds, and it scrubs
/// anything that looks like a credential before printing — Xtream stream URLs
/// carry the username and password in the path, so they get logged constantly
/// if nobody guards against it.
abstract final class Log {
  static final _credentialPath = RegExp(r'(/(?:live|movie|series)/)[^/]+/[^/]+/');
  static final _credentialQuery =
      RegExp(r'([?&](?:username|password|key)=)[^&]*', caseSensitive: false);

  static String redact(Object? value) => value
      .toString()
      .replaceAllMapped(_credentialPath, (m) => '${m[1]}***/***/')
      .replaceAllMapped(_credentialQuery, (m) => '${m[1]}***');

  static void d(String tag, Object? message) {
    if (!kDebugMode) return;
    developer.log(redact(message), name: tag);
  }

  static void i(String tag, Object? message) {
    if (!kDebugMode) return;
    developer.log(redact(message), name: tag);
  }

  static void w(String tag, Object? message) {
    if (!kDebugMode) return;
    developer.log('WARN ${redact(message)}', name: tag);
  }

  static void e(String tag, Object? message, [Object? error, StackTrace? stack]) {
    if (!kDebugMode) return;
    developer.log(
      'ERROR ${redact(message)}',
      name: tag,
      error: error == null ? null : redact(error),
      stackTrace: stack,
    );
  }
}
