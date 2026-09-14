import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Thin wrapper around SharedPreferences for everything the app needs to
/// persist: saved logins, watch history and favorites, and player settings.
class Storage {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static SharedPreferences get p => _prefs!;

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

  static Future<void> saveAccounts(List<Account> accounts) async {
    await p.setString('accounts', jsonEncode(accounts.map((a) => a.toJson()).toList()));
  }

  static String? getActiveAccountId() => p.getString('activeAccountId');
  static Future<void> setActiveAccountId(String? id) async {
    if (id == null) {
      await p.remove('activeAccountId');
    } else {
      await p.setString('activeAccountId', id);
    }
  }

  // ---- Settings ----
  static String getQuality() => p.getString('quality') ?? 'auto';
  static Future<void> setQuality(String q) => p.setString('quality', q);

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
    if (list.length > 60) list.removeRange(60, list.length);
    await p.setString('history', jsonEncode(list.map((e) => e.toJson()).toList()));
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
