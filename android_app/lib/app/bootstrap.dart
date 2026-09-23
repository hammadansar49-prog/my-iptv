import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../core/utils/app_orientation.dart';

import '../core/security/device_identity.dart';
import '../core/storage/local_store.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/logger.dart';
import '../services/player/background_playback_guard.dart';
import '../services/notifications/announcement_push.dart';
import '../presentation/providers.dart';

/// Everything that must exist before the first frame.
///
/// Spec §8 forbids an infinite or frozen splash, so this is deliberately
/// short and every step is failure-tolerant: a step that throws degrades to
/// a sane default rather than blocking startup.
class Bootstrap {
  const Bootstrap({
    required this.localStore,
    required this.isTv,
  });

  final LocalStore localStore;
  final bool isTv;

  static const _tag = 'Bootstrap';

  static Future<Bootstrap> run() async {
    WidgetsFlutterBinding.ensureInitialized();

    // libmpv has to be initialised before any Player is constructed.
    MediaKit.ensureInitialized();

    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemOverlay);

    final store = await LocalStore.open();

    // Optional FCM; never blocks or fails startup (no google-services.json
    // yet). Taps that arrive before the live controller listens are queued.
    unawaited(AnnouncementPush.init());

    var isTv = false;
    try {
      isTv = await DeviceIdentity().isAndroidTv();
    } catch (e) {
      Log.w(_tag, 'TV detection failed, assuming handset: $e');
    }

    // TV landscape, phone portrait; the players go landscape while
    // fullscreen and restore this on exit (spec §53).
    await AppOrientation.restore(isTv: isTv);

    BackgroundPlaybackGuard.install();
    Log.i(_tag, 'ready (tv=$isTv)');
    return Bootstrap(localStore: store, isTv: isTv);
  }

  /// Provider overrides for the composition root.
  List<Override> get overrides => [
        localStoreProvider.overrideWithValue(localStore),
        isTvProvider.overrideWithValue(isTv),
      ];
}
