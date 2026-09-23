import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// Taps on the "MY IPTV" announcement notification, from either source:
/// the native WorkManager/FCM-data notification (MethodChannel pull) or an
/// FCM notification-payload message drawn by the FCM SDK.
///
/// FCM is optional: without android/app/google-services.json
/// `Firebase.initializeApp` throws, which is caught and the app runs as
/// before (the WorkManager poll still delivers announcements).
abstract final class AnnouncementPush {
  static const _tag = 'AnnouncementPush';
  static const topic = 'iptv_announcements';
  static const _channel = MethodChannel('theottdeals/announcements');

  static final _taps = StreamController<int?>.broadcast();

  /// created_at of the tapped announcement (null = "whatever is current").
  static Stream<int?> get taps => _taps.stream;

  /// A tap that arrived before anyone listened (cold start).
  static int? pendingTap;
  static bool hasPendingTap = false;

  static void _emit(int? createdAt) {
    if (_taps.hasListener) {
      _taps.add(createdAt);
    } else {
      pendingTap = createdAt;
      hasPendingTap = true;
    }
  }

  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
    } catch (e) {
      Log.i(_tag, 'Firebase not configured, push disabled: $e');
      return;
    }
    try {
      final fm = FirebaseMessaging.instance;
      // Foreground messages are intentionally not listened to: the live SSE
      // popup already shows the announcement.
      await fm.subscribeToTopic(topic);
      final initial = await fm.getInitialMessage();
      if (initial != null) _emit(_createdAt(initial));
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _emit(_createdAt(m)));
    } catch (e) {
      Log.w(_tag, 'FCM setup failed: $e');
    }
  }

  /// Native notification tap (launch or resume). Cheap; call on every resume.
  static Future<void> checkNativeTap() async {
    try {
      final v = await _channel.invokeMethod<int>('takePendingTap');
      if (v != null) _emit(v);
    } catch (e) {
      Log.w(_tag, 'native tap check failed: $e');
    }
  }

  static int? _createdAt(RemoteMessage m) =>
      num.tryParse('${m.data['created_at'] ?? ''}')?.toInt();
}
