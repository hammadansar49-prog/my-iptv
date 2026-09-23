import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../utils/logger.dart';

/// Android equivalent of main.js's `getMachineId()`.
///
/// CLAUDE.md is emphatic: changing this formula re-binds every already-
/// activated key, so whatever is chosen must be frozen from day one. The PC
/// app folds in a MAC address specifically because it survives a reinstall;
/// Android does not expose the MAC any more, so the stable inputs available
/// without extra permissions are used instead:
///
///   ANDROID_ID (Settings.Secure, read natively via DeviceIdBridge — NOT
///   `androidInfo.id`, which is Build.ID) — per device, survives app
///   reinstall, resets only on factory reset / different signing key.
///
/// The result is sha256-hashed so nothing device-identifying is ever sent or
/// logged in the clear, exactly as the PC app does.
class DeviceIdentity {
  DeviceIdentity({DeviceInfoPlugin? plugin})
      : _plugin = plugin ?? DeviceInfoPlugin();

  static const _tag = 'DeviceIdentity';

  final DeviceInfoPlugin _plugin;
  static const _device = MethodChannel('theottdeals/device');
  String? _cached;
  AndroidDeviceInfo? _info;

  Future<AndroidDeviceInfo?> androidInfo() async {
    try {
      return _info ??= await _plugin.androidInfo;
    } catch (e) {
      Log.e(_tag, 'androidInfo failed', e);
      return null;
    }
  }

  /// Stable per-device id. Cached for the process lifetime.
  Future<String> machineId() async {
    final cached = _cached;
    if (cached != null) return cached;

    // ANDROID_ID only. `AndroidDeviceInfo.id` is NOT the Android ID — it is
    // Build.ID, the firmware build string — so the previous formula (that
    // plus fingerprint/model/hardware/board) was identical for every phone
    // of the same model and update: a second such phone saw no free trial
    // and shared the first one's licence binding, and an OS update changed
    // it. ANDROID_ID is per device (and per signing key), survives
    // reinstalls, and resets only on factory reset.
    String? androidId;
    try {
      androidId = await _device.invokeMethod<String>('androidId');
    } catch (e) {
      Log.e(_tag, 'androidId failed', e);
    }
    final String basis;
    if (androidId != null && androidId.isNotEmpty) {
      basis = 'android-id|$androidId';
    } else {
      final info = await androidInfo();
      basis = info == null
          ? 'unknown-device'
          : [info.id, info.fingerprint, info.model, info.hardware, info.board]
              .join('|');
    }
    final digest = sha256.convert(utf8.encode(basis));
    return _cached = digest.toString();
  }

  /// Human-readable device label for the account screen (spec §34).
  Future<String> displayName() async {
    final info = await androidInfo();
    if (info == null) return 'This device';
    return '${info.manufacturer} ${info.model} (Android ${info.version.release})';
  }

  /// Android TV detection drives the whole adaptive-UI decision (spec §36).
  /// `systemFeatures` is the reliable signal; a TV always reports leanback.
  Future<bool> isAndroidTv() async {
    final info = await androidInfo();
    if (info == null) return false;
    const leanback = 'android.software.leanback';
    const television = 'android.hardware.type.television';
    return info.systemFeatures.contains(leanback) ||
        info.systemFeatures.contains(television);
  }
}
