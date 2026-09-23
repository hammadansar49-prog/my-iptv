import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/utils/logger.dart';
import 'pip_service.dart';
import 'player_controller.dart';

/// Stops sound when the app leaves the screen — for every player (full
/// player, inline Live TV, EPG).
///
/// The Flutter engine is cached and outlives the Activity (so downloads keep
/// running), which means leaving the app no longer tears the player down:
/// a movie kept playing audio after the user closed the app. A PiP window is
/// the one legitimate way to keep playing in the background, so on leaving
/// the screen we give Android a moment to open PiP, ask it directly whether
/// a PiP window is showing, and otherwise pause (VOD) / stop (live).
abstract final class BackgroundPlaybackGuard {
  static AppLifecycleListener? _listener;
  static Timer? _check;
  static bool _visible = true;

  static void install() {
    _listener ??= AppLifecycleListener(onStateChange: _onState);
  }

  static void _onState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _visible = true;
        _check?.cancel();
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _visible = false;
        _check?.cancel();
        _check = Timer(const Duration(milliseconds: 800), () async {
          if (_visible) return;
          if (await PipService.isInPipNow()) return;
          Log.i('BackgroundGuard', 'app left the screen — pausing playback');
          await PlayerController.backgroundActive();
        });
      case AppLifecycleState.detached:
        _check?.cancel();
        unawaited(PlayerController.stopActive());
    }
  }
}
