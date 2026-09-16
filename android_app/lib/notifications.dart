import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System notifications for admin announcements — separate from the in-app
/// dialog (announcement_dialog.dart) that already shows on launch and on
/// live push. This is what lets an announcement reach the user even while
/// they're not looking at the app, the way a "real" app does it, and
/// tapping it brings them straight to the same dialog via [onTapped].
class AppNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;
  static VoidCallback? _onAnnouncementTapped;

  /// Requests the POST_NOTIFICATIONS permission (Android 13+; a no-op that
  /// just returns granted on older versions) — called once at app boot, not
  /// tied to any particular announcement, so the prompt appears right away
  /// instead of the first time one is actually published.
  static Future<void> init({VoidCallback? onTapped}) async {
    _onAnnouncementTapped = onTapped;
    if (_inited) return;
    _inited = true;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload == 'announcement') _onAnnouncementTapped?.call();
      },
    );
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> showAnnouncement(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'announcements',
      'Announcements',
      channelDescription: 'New announcements from MY IPTV',
      importance: Importance.high,
      priority: Priority.high,
    );
    try {
      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        const NotificationDetails(android: androidDetails),
        payload: 'announcement',
      );
    } catch (_) {
      // Permission not granted, or unsupported — the in-app dialog still
      // covers this, so failing quietly here is fine.
    }
  }
}
