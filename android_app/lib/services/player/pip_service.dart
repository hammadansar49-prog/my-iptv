import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// Picture-in-Picture glue (`PipBridge.kt`).
///
/// The player screen keeps the native params in step ([configure]) so Home
/// auto-enters PiP while a video plays, and calls [enter] from its button.
/// [inPip] drives what Flutter paints: in PiP only the video, no controls
/// or app-wide overlays. [onDismissed] fires when the user closes the PiP
/// window (X) rather than expanding it.
abstract final class PipService {
  static const _tag = 'Pip';
  static const _channel = MethodChannel('theottdeals/pip');

  static final ValueNotifier<bool> inPip = ValueNotifier(false);

  /// Set by the screen that owns the playing video.
  static VoidCallback? onDismissed;

  static bool _listening = false;
  static bool? _supported;
  static String? _lastConfig;

  static void _ensureListening() {
    if (_listening || !Platform.isAndroid) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'changed') return null;
      final args = (call.arguments as Map).cast<String, dynamic>();
      final pip = args['inPip'] == true;
      inPip.value = pip;
      if (!pip && args['dismissed'] == true) onDismissed?.call();
      return null;
    });
  }

  static Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    _ensureListening();
    if (_supported != null) return _supported!;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (e) {
      Log.w(_tag, 'isSupported failed: $e');
      _supported = false;
    }
    return _supported!;
  }

  /// [autoEnter]: go PiP when the user presses Home. [aspect]: the video's
  /// width/height (clamped natively to what Android allows).
  static Future<void> configure({
    required bool autoEnter,
    double? aspect,
  }) async {
    if (!Platform.isAndroid) return;
    _ensureListening();
    final sig = '$autoEnter|${aspect?.toStringAsFixed(3)}';
    if (sig == _lastConfig) return;
    _lastConfig = sig;
    try {
      await _channel.invokeMethod('configure', {
        'autoEnter': autoEnter,
        'aspect': aspect,
      });
    } catch (e) {
      Log.w(_tag, 'configure failed: $e');
    }
  }

  static Future<bool> enter({double? aspect}) async {
    if (!Platform.isAndroid) return false;
    _ensureListening();
    try {
      return await _channel.invokeMethod<bool>('enter', {'aspect': aspect}) ??
          false;
    } catch (e) {
      Log.w(_tag, 'enter failed: $e');
      return false;
    }
  }
}
