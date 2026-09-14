import 'package:flutter/foundation.dart' hide Category;
import 'models.dart';
import 'storage.dart';
import 'xtream_client.dart';

class AppState extends ChangeNotifier {
  Account? activeAccount;
  XtreamClient? client;
  Map<String, dynamic>? authInfo;

  List<HistoryEntry> history = [];
  List<FavoriteEntry> favorites = [];
  String quality = 'auto';
  String defaultSection = 'movies'; // all | movies | series | live
  String defaultPlayer = 'internal'; // internal | vlc
  String refreshInterval = '1day';  // never | 6h | 1day | 1week

  // Shared across Home/Profile/EPG so nothing gets fetched twice.
  final Map<String, List<Category>> catCache = {};
  final Map<String, List<PlayableItem>> itemCache = {};

  Future<void> init() async {
    await Storage.init();
    history = Storage.getHistory();
    favorites = Storage.getFavorites();
    quality = Storage.getQuality();
    defaultSection = Storage.p.getString('defaultSection') ?? 'movies';
    defaultPlayer = Storage.p.getString('defaultPlayer') ?? 'internal';
    refreshInterval = Storage.p.getString('refreshInterval') ?? '1day';
  }

  Future<void> setDefaultSection(String s) async {
    defaultSection = s;
    await Storage.p.setString('defaultSection', s);
    notifyListeners();
  }

  Future<void> setDefaultPlayer(String p) async {
    defaultPlayer = p;
    await Storage.p.setString('defaultPlayer', p);
    notifyListeners();
  }

  Future<void> setRefreshInterval(String v) async {
    refreshInterval = v;
    await Storage.p.setString('refreshInterval', v);
    notifyListeners();
  }

  List<Account> get savedAccounts => Storage.getAccounts();

  Future<void> saveAccount(Account acc) async {
    final list = Storage.getAccounts();
    final idx = list.indexWhere((a) => a.type == acc.type && a.url == acc.url && a.username == acc.username);
    if (idx >= 0) {
      list[idx] = acc;
    } else {
      list.insert(0, acc);
    }
    await Storage.saveAccounts(list);
  }

  Future<void> removeAccount(String id) async {
    final list = Storage.getAccounts()..removeWhere((a) => a.id == id);
    await Storage.saveAccounts(list);
    notifyListeners();
  }

  Future<void> login(Account acc) async {
    final c = XtreamClient(baseUrl: acc.url, username: acc.username, password: acc.password);
    final auth = await c.authenticate(); // throws XtreamException on failure
    client = c;
    activeAccount = acc;
    authInfo = auth;
    await saveAccount(acc);
    await Storage.setActiveAccountId(acc.id);
    notifyListeners();
  }

  Future<void> tryAutoLogin() async {
    final id = Storage.getActiveAccountId();
    if (id == null) return;
    final acc = Storage.getAccounts().where((a) => a.id == id).firstOrNull;
    if (acc == null) return;
    try {
      await login(acc);
    } catch (_) {
      // silently fall back to the login screen
    }
  }

  Future<void> logout() async {
    client = null;
    activeAccount = null;
    authInfo = null;
    await Storage.setActiveAccountId(null);
    notifyListeners();
  }

  Future<void> setQuality(String q) async {
    quality = q;
    await Storage.setQuality(q);
    notifyListeners();
  }

  // ---- History ----
  HistoryEntry? findHistory(String key) {
    for (final h in history) {
      if (h.key == key) return h;
    }
    return null;
  }

  Future<void> upsertHistory(PlayRequest req, {required double resumeAt, required double duration}) async {
    if (req.isLive) return;
    history.removeWhere((h) => h.key == req.historyKey);
    history.insert(
      0,
      HistoryEntry(
        key: req.historyKey,
        type: req.type,
        title: req.title,
        subtitle: req.subtitle,
        thumb: req.thumb,
        url: req.url,
        isLive: req.isLive,
        resumeAt: resumeAt,
        duration: duration,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await Storage.saveHistory(history);
    notifyListeners();
  }

  List<HistoryEntry> get continueWatching => history
      .where((h) => !h.isLive && h.duration > 0 && h.resumeAt > 5 && h.resumeAt < h.duration * 0.95)
      .toList();

  // ---- Favorites ----
  String favKey(String section, PlayableItem item) => '$section:${item.id}';

  bool isFavorite(String section, PlayableItem item) =>
      favorites.any((f) => f.key == favKey(section, item));

  Future<void> toggleFavorite(String section, PlayableItem item) async {
    final key = favKey(section, item);
    final idx = favorites.indexWhere((f) => f.key == key);
    if (idx >= 0) {
      favorites.removeAt(idx);
    } else {
      favorites.insert(0, FavoriteEntry(key: key, section: section, item: item));
    }
    await Storage.saveFavorites(favorites);
    notifyListeners();
  }
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
