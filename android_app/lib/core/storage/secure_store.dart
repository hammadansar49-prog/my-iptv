import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/logger.dart';

/// Credentials only. The PC app keeps username/password in plain `store.json`
/// because it is a desktop app behind an OS account; on Android they belong in
/// the keystore (spec §7, §51). Nothing else goes in here — secure storage is
/// slow and small.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const _tag = 'SecureStore';
  static const _kAccounts = 'accounts.v1';
  static const _kActiveAccountId = 'active_account_id.v1';
  static const _kLicense = 'license.v1';
  static const _kAppLockPin = 'app_lock_pin.v1';

  final FlutterSecureStorage _storage;

  Future<List<Map<String, dynamic>>> readAccounts() async {
    final raw = await _read(_kAccounts);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (e) {
      Log.w(_tag, 'accounts unreadable, starting empty: $e');
      return const [];
    }
  }

  Future<void> writeAccounts(List<Map<String, dynamic>> accounts) =>
      _write(_kAccounts, jsonEncode(accounts));

  Future<String?> readActiveAccountId() => _read(_kActiveAccountId);

  Future<void> writeActiveAccountId(String? id) =>
      id == null ? _delete(_kActiveAccountId) : _write(_kActiveAccountId, id);

  Future<Map<String, dynamic>?> readLicense() async {
    final raw = await _read(_kLicense);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      return m is Map ? m.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeLicense(Map<String, dynamic>? license) => license == null
      ? _delete(_kLicense)
      : _write(_kLicense, jsonEncode(license));

  /// The app-lock PIN (Profile → Security). Null means locking is off — its
  /// absence IS the "disabled" state, not a separate flag to keep in sync.
  Future<String?> readAppLockPin() => _read(_kAppLockPin);

  Future<void> writeAppLockPin(String pin) => _write(_kAppLockPin, pin);

  Future<void> clearAppLockPin() => _delete(_kAppLockPin);

  Future<void> clear() async {
    await _delete(_kAccounts);
    await _delete(_kActiveAccountId);
    await _delete(_kLicense);
    // App lock deliberately survives sign-out/account switches — it protects
    // the device, not one playlist.
  }

  // Secure storage can throw on some devices (corrupt keystore after a
  // restore, for instance). A read failure must degrade to "logged out",
  // never to a crash on the splash screen.
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      Log.e(_tag, 'read $key failed', e);
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      Log.e(_tag, 'write $key failed', e);
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      Log.e(_tag, 'delete $key failed', e);
    }
  }
}
