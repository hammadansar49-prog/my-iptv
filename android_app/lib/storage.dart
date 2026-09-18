import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Thin wrapper around SharedPreferences + FlutterSecureStorage for
/// everything the app needs to persist: saved logins (passwords in secure
/// storage), watch history and favorites, and player settings.
class Storage {
  static SharedPreferences? _prefs;
  static FlutterSecureStorage? _secure;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _secure ??= const FlutterSecureStorage();
    await _migratePlaintextPasswords();
  }

  /// One-time migration: move any passwords still stored in plaintext
  /// SharedPreferences into FlutterSecureStorage (Android Keystore-backed).
  /// Safe to call on every launch — once migrated, the plaintext key is
  /// removed so subsequent calls are no-ops.
  static Future<void> _migratePlaintextPasswords() async {
    final raw = _prefs!.getString('accounts');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      bool changed = false;
      for (final e in list) {
        final m = Map<String, dynamic>.from(e);
        final id = m['id'] as String?;
        final plainPw = m['password'] as String?;
        if (id != null && plainPw != null && plainPw.isNotEmpty) {
          // Check if already in secure storage
          final stored = await _secure!.read(key: 'pw_$id');
          if (stored == null) {
            await _secure!.write(key: 'pw_$id', value: plainPw);
          }
          // Remove plaintext from the accounts JSON
          m['password'] = '';
          changed = true;
        }
      }
      if (changed) {
        await _prefs!.setString('accounts', jsonEncode(list));
      }
    } catch (_) {}
  }

  static SharedPreferences get p {
    if (_prefs == null) throw StateError('Storage not initialized. Call Storage.init() first.');
    return _prefs!;
  }

  static FlutterSecureStorage get s {
    if (_secure == null) throw StateError('Storage not initialized. Call Storage.init() first.');
    return _secure!;
  }

  // ---- Accounts ----
  static List<Account> getAccounts() {
    final raw = p.getString('accounts');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Account.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  /// Read the password for [accountId] from secure storage.
  static Future<String> getPassword(String accountId) async {
    return await s.read(key: 'pw_$accountId') ?? '';
  }

  /// Write the password for [accountId] to secure storage.
  static Future<void> savePassword(String accountId, String password) async {
    await s.write(key: 'pw_$accountId', value: password);
  }

  /// Remove the password for [accountId] from secure storage.
  static Future<void> deletePassword(String accountId) async {
    await s.delete(key: 'pw_$accountId');
  }

  static Future<void> saveAccounts(List<Account> accounts) async {
    // Strip passwords from the JSON before saving to SharedPreferences.
    final safe = accounts.map((a) {
      final j = a.toJson();
      j['password'] = '';
      return j;
    }).toList();
    await p.setString('accounts', jsonEncode(safe));
  }

  static String? getActiveAccountId() => p.getString('activeAccountId');
  static Future<void> setActiveAccountId(String? id) async {
    if (id == null) {
      await p.remove('activeAccountId');
    } else {
      await p.setString('activeAccountId', id);
    }
  }

  // ---- Simple settings ----
  static String str(String key, String fallback) => p.getString(key) ?? fallback;
  static bool flag(String key, bool fallback) => p.getBool(key) ?? fallback;
  static Future<void> setStr(String key, String value) => p.setString(key, value);
  static Future<void> setFlag(String key, bool value) => p.setBool(key, value);

  // ---- History (Continue Watching / Recently Watched) ----
  static List<HistoryEntry> getHistory() {
    final raw = p.getString('history');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => HistoryEntry.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveHistory(List<HistoryEntry> list) async {
    final truncated = list.length > 80 ? list.sublist(0, 80) : list;
    await p.setString('history', jsonEncode(truncated.map((e) => e.toJson()).toList()));
  }

  // ---- Favorites ----
  static List<FavoriteEntry> getFavorites() {
    final raw = p.getString('favorites');
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) {
            try {
              return FavoriteEntry.fromJson(Map<String, dynamic>.from(e));
            } catch (_) {
              return null;
            }
          })
          .whereType<FavoriteEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveFavorites(List<FavoriteEntry> list) async {
    await p.setString('favorites', jsonEncode(list.map((e) => e.toJson()).toList()));
  }
}
