import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// What a runtime permission currently looks like to the app.
enum AppPermissionStatus {
  granted,

  /// Not granted, but the system dialog can still be shown.
  denied,

  /// The system will not ask again; only the app's settings page can change
  /// it (or, below Android 13, notifications are switched off there).
  permanentlyDenied,
}

/// The two runtime permissions the app asks for, always after its own
/// explanation — never automatically at launch (`PermissionBridge.kt`).
enum AppPermission {
  /// POST_NOTIFICATIONS (Android 13+): announcements, download progress.
  notifications('notifications'),

  /// READ_MEDIA_VIDEO (13+) / external storage (12 and below): finished
  /// downloads are published to the Gallery.
  media('media');

  const AppPermission(this.kind);
  final String kind;
}

abstract final class PermissionService {
  static const _tag = 'Permissions';
  static const _channel = MethodChannel('theottdeals/permissions');

  static AppPermissionStatus _parse(Object? v) => switch (v) {
        'granted' => AppPermissionStatus.granted,
        'permanentlyDenied' => AppPermissionStatus.permanentlyDenied,
        _ => AppPermissionStatus.denied,
      };

  static Future<AppPermissionStatus> status(AppPermission p) async {
    if (!Platform.isAndroid) return AppPermissionStatus.granted;
    try {
      return _parse(await _channel.invokeMethod('status', {'kind': p.kind}));
    } catch (e) {
      Log.w(_tag, 'status failed: $e');
      return AppPermissionStatus.denied;
    }
  }

  /// Shows the system dialog when it still can; otherwise just reports.
  static Future<AppPermissionStatus> request(AppPermission p) async {
    if (!Platform.isAndroid) return AppPermissionStatus.granted;
    try {
      return _parse(await _channel.invokeMethod('request', {'kind': p.kind}));
    } catch (e) {
      Log.w(_tag, 'request failed: $e');
      return AppPermissionStatus.denied;
    }
  }

  /// The app's notification settings (or app details for media).
  static Future<void> openSettings(AppPermission p) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openSettings', {'kind': p.kind});
    } catch (e) {
      Log.w(_tag, 'openSettings failed: $e');
    }
  }
}
