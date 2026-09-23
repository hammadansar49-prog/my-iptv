import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Structured logging (spec §50). Silent in release builds, and it scrubs
/// anything that looks like a credential before printing — Xtream stream URLs
/// carry the username and password in the path, so they get logged constantly
/// if nobody guards against it.
///
/// Every line goes to both `developer.log` (structured, for DevTools) and
/// `debugPrint`. The second one matters: `developer.log` alone never shows
/// up in `adb logcat` or the `flutter run`/`attach` console, which made a
/// real on-device loading bug look like "nothing is happening at all" when
/// the app was in fact logging every step.
abstract final class Log {
  static final _credentialPath = RegExp(r'(/(?:live|movie|series)/)[^/]+/[^/]+/');
  static final _credentialQuery =
      RegExp(r'([?&](?:username|password|key)=)[^&]*', caseSensitive: false);

  static String redact(Object? value) => value
      .toString()
      .replaceAllMapped(_credentialPath, (m) => '${m[1]}***/***/')
      .replaceAllMapped(_credentialQuery, (m) => '${m[1]}***');

  static void _emit(String tag, String line, [Object? error, StackTrace? stack]) {
    developer.log(line, name: tag, error: error, stackTrace: stack);
    debugPrint('[$tag] $line${error == null ? '' : ' | $error'}');
  }

  static void d(String tag, Object? message) {
    if (!kDebugMode) return;
    _emit(tag, redact(message));
  }

  static void i(String tag, Object? message) {
    if (!kDebugMode) return;
    _emit(tag, redact(message));
  }

  static void w(String tag, Object? message) {
    if (!kDebugMode) return;
    _emit(tag, 'WARN ${redact(message)}');
  }

  static void e(String tag, Object? message, [Object? error, StackTrace? stack]) {
    if (!kDebugMode) return;
    _emit(
      tag,
      'ERROR ${redact(message)}',
      error == null ? null : redact(error),
      stack,
    );
  }
}
