import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/utils/logger.dart';

/// Dart side of `GalleryBridge.kt`: moves a finished download into the
/// phone's Gallery (Movies/MY IPTV) and reports where it now lives.
class GalleryBridge {
  static const _tag = 'Gallery';
  static const _channel = MethodChannel('theottdeals/gallery');

  static String mimeFor(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      'ts' => 'video/mp2t',
      'webm' => 'video/webm',
      'mov' => 'video/quicktime',
      '3gp' => 'video/3gpp',
      _ => 'video/mp4',
    };
  }

  /// Returns the new playable path, or null if publishing failed (the
  /// private file is then left untouched and still plays).
  Future<String?> publish(String path, {required String title}) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('publishVideo', {
        'path': path,
        'displayName': path.split(Platform.pathSeparator).last,
        'title': title,
        'mime': mimeFor(path),
      });
    } catch (e) {
      Log.w(_tag, 'publish failed: $e');
      return null;
    }
  }

  /// Delete a published video (MediaStore row + file).
  Future<bool> delete(String path) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('deleteVideo', {'path': path}) ??
          false;
    } catch (e) {
      Log.w(_tag, 'delete failed: $e');
      return false;
    }
  }
}
