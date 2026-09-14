import 'dart:io';
import 'package:flutter/foundation.dart' hide Category;
import 'package:path_provider/path_provider.dart';
import 'downloads.dart';
import 'models.dart';
import 'storage.dart';
import 'xtream_client.dart';

class AppState extends ChangeNotifier {
  Account? activeAccount;
  XtreamClient? client;
  Map<String, dynamic>? authInfo;
  Directory? _cacheDir;

  final DownloadManager downloads = DownloadManager();

  List<HistoryEntry> history = [];
  List<FavoriteEntry> favorites = [];

  // ---- Settings ----
  String quality = 'auto';          // highest stream variant to pick: auto | 480 | 720 | 1080 | 2160
  String liveFormat = 'm3u8';       // m3u8 | ts
  String defaultSection = 'movies'; // movies | series | live
  String refreshInterval = '1day';  // never | 6h | 1day | 1week
  bool resume = true;               // reopen films where they were left
  bool autoNext = true;             // roll into the next episode
  int seekStep = 10;                // seconds for double-tap / skip buttons
  String audioLang = '';            // last audio language picked in the player
  String subtitleLang = '';         // last subtitle language picked ('' = off)
  String passcode = '';             // app lock ('' = off)

  // Shared across Home/Profile/EPG so nothing gets fetched twice.
  final Map<String, List<Category>> catCache = {};
  final Map<String, List<PlayableItem>> itemCache = {};

  int get maxConnections => int.tryParse('${authInfo?['user_info']?['max_connections'] ?? ''}') ?? 1;

  Future<void> init() async {
    await Storage.init();
    try {
      _cacheDir = await getApplicationSupportDirectory();
    } catch (_) {}
    history = Storage.getHistory();
    favorites = Storage.getFavorites();
    quality = Storage.str('quality', 'auto');
    liveFormat = Storage.str('liveFormat', 'm3u8');
    defaultSection = Storage.str('defaultSection', 'movies');
    if (!['movies', 'series', 'live'].contains(defaultSection)) defaultSection = 'movies';
    refreshInterval = Storage.str('refreshInterval', '1day');
    resume = Storage.flag('resume', true);
    autoNext = Storage.flag('autoNext', true);
    seekStep = int.tryParse(Storage.str('seekStep', '10')) ?? 10;
    audioLang = Storage.str('audioLang', '');
    subtitleLang = Storage.str('subtitleLang', '');
    passcode = Storage.str('passcode', '');
    await downloads.init();
  }

  Future<void> setStr(String key, String value) async {
    switch (key) {
      case 'quality': quality = value; break;
      case 'liveFormat': liveFormat = value; break;
      case 'defaultSection': defaultSection = value; break;
      case 'refreshInterval': refreshInterval = value; break;
      case 'seekStep': seekStep = int.tryParse(value) ?? 10; break;
      case 'audioLang': audioLang = value; break;
      case 'subtitleLang': subtitleLang = value; break;
      case 'passcode': passcode = value; break;
    }
    await Storage.setStr(key, value);
    notifyListeners();
  }

  Future<void> setFlag(String key, bool value) async {
    switch (key) {
      case 'resume': resume = value; break;
      case 'autoNext': autoNext = value; break;
    }
    await Storage.setFlag(key, value);
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
    final c = XtreamClient(baseUrl: acc.url, username: acc.username, password: acc.password, cacheDir: _cacheDir);
    final auth = await c.authenticate(); // throws XtreamException on failure
    if (activeAccount?.id != acc.id) {
      catCache.clear();
      itemCache.clear();
    }
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
    catCache.clear();
    itemCache.clear();
    await Storage.setActiveAccountId(null);
    notifyListeners();
  }

  /// Drops everything cached for the catalog; the next screen that needs a
  /// list fetches it fresh.
  Future<void> refreshCatalog() async {
    catCache.clear();
    itemCache.clear();
    await client?.clearCatalogCache();
    notifyListeners();
  }

  /// The full list for a section, from memory, the disk cache or the network.
  Future<List<PlayableItem>> sectionItems(String section, {String? categoryId, bool force = false}) async {
    final key = '$section:${categoryId ?? 'all'}';
    final cached = itemCache[key];
    if (cached != null && cached.isNotEmpty && !force) return cached;
    final c = client!;
    final list = section == 'live'
        ? await c.getLiveStreams(categoryId, force: force)
        : section == 'movies'
            ? await c.getVodStreams(categoryId, force: force)
            : await c.getSeries(categoryId, force: force);
    // An empty list is not remembered: that's what a failed or cut-off
    // answer looks like, and keeping it showed "0 items" until a restart.
    if (list.isNotEmpty) itemCache[key] = list;
    return list;
  }

  Future<List<Category>> sectionCategories(String section) async {
    final cached = catCache[section];
    if (cached != null && cached.isNotEmpty) return cached;
    final c = client!;
    final list = section == 'live'
        ? await c.getLiveCategories()
        : section == 'movies'
            ? await c.getVodCategories()
            : await c.getSeriesCategories();
    if (list.isNotEmpty) catCache[section] = list;
    return list;
  }

  String liveUrl(String streamId) => client!.liveUrl(streamId, ext: liveFormat == 'ts' ? 'ts' : 'm3u8');

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
