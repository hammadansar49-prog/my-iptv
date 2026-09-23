import 'package:flutter/services.dart';

/// The app's resting orientation outside fullscreen video.
///
/// Phones are portrait-only: the whole UI is designed portrait, and allowing
/// landscape here meant that leaving a (landscape) player left the entire
/// app stuck sideways until the phone was physically turned. Only the video
/// players switch to landscape, and they call [restore] on the way out.
/// A TV is always landscape.
abstract final class AppOrientation {
  static Future<void> restore({required bool isTv}) =>
      SystemChrome.setPreferredOrientations(
        isTv
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      );
}
