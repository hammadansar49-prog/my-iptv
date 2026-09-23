import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// Dart side of the native Android foreground service
/// (`DownloadService.kt`). The service owns the ongoing notification and
/// keeps the process — and with it the cached main Flutter engine that runs
/// [DownloadManager] — alive while downloads are active, including after the
/// app is swiped away from recents. It never downloads anything itself, so
/// there is exactly one downloader and one source of truth.
class DownloadServiceBridge {
  DownloadServiceBridge() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(_onCall);
  }

  static const _tag = 'DownloadService';
  static const _channel = MethodChannel('theottdeals/download_service');

  /// Notification button taps: ('pause' | 'resume' | 'cancel', itemId).
  void Function(String action, String id)? onAction;

  bool _running = false;
  bool _askedPermission = false;
  String? _lastSig;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'action') {
      final args = (call.arguments as Map).cast<String, dynamic>();
      onAction?.call('${args['action']}', '${args['id']}');
    }
    return null;
  }

  /// Android 13+: ask once, at the first download.
  Future<void> ensureNotificationPermission() async {
    if (!Platform.isAndroid || _askedPermission) return;
    _askedPermission = true;
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (e) {
      Log.w(_tag, 'permission request failed: $e');
    }
  }

  /// Start (or refresh) the foreground notification.
  Future<void> show({
    required String id,
    required String title,
    required int percent,
    required String detail,
    required bool paused,
  }) async {
    if (!Platform.isAndroid) return;
    final sig = '$id|$title|$percent|$detail|$paused';
    if (_running && sig == _lastSig) return;
    _lastSig = sig;
    try {
      await _channel.invokeMethod(_running ? 'update' : 'start', {
        'id': id,
        'title': title,
        'percent': percent,
        'detail': detail,
        'paused': paused,
      });
      _running = true;
    } catch (e) {
      // e.g. ForegroundServiceStartNotAllowedException when asked from the
      // background; the next tick tries again.
      Log.w(_tag, 'show failed: $e');
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    _running = false;
    _lastSig = null;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      Log.w(_tag, 'stop failed: $e');
    }
  }
}
