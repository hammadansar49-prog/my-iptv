import '../../data/api/rtdb_api.dart';
import '../../data/models/account.dart';
import '../../data/models/content.dart';
import '../../data/models/epg.dart';
import '../../data/models/library.dart';

/// Repository contracts. The presentation layer depends on these, never on
/// XtreamApi/RtdbApi directly, so the whole app can be driven by fakes in
/// tests (spec §5, §67).

abstract interface class AuthRepository {
  /// Accounts saved on this device, most recently used first.
  Future<List<Account>> savedAccounts();

  /// Validate credentials against the panel and make the account active.
  Future<XtreamSession> signIn(Account account, {bool remember = true});

  /// Re-authenticate the stored active account on launch (spec §7).
  /// Returns null when there is nothing saved.
  Future<XtreamSession?> restoreSession();

  Future<void> removeAccount(String accountId);

  Future<void> signOut();

  Account? get activeAccount;
  XtreamSession? get activeSession;
}

abstract interface class ContentRepository {
  Future<List<Category>> categories(ContentSection section);

  Future<List<LiveChannel>> liveChannels({String? categoryId});
  Future<List<Movie>> movies({String? categoryId});
  Future<List<Series>> seriesList({String? categoryId});

  Future<MovieDetail?> movieDetail(Movie movie);
  Future<SeriesDetail?> seriesDetail(Series series);

  /// Scoped search (spec §13/§15/§17/§18). Each of these only ever returns
  /// its own kind of result — there is no cross-section leakage.
  Future<List<LiveChannel>> searchChannels(String query);
  Future<List<Movie>> searchMovies(String query);
  Future<List<Series>> searchSeries(String query);

  Future<ChannelGuide> guideFor(LiveChannel channel);
  Future<List<EpgProgramme>> fullGuide(LiveChannel channel);

  String liveUrl(LiveChannel channel, {String? ext});
  String movieUrl(Movie movie);
  String episodeUrl(Episode episode);

  /// Fetch one section's full catalogue into the cache ahead of time — the
  /// post-login loading screen. [onBytes] reports real download progress
  /// (`total` is -1 when the panel sends no Content-Length). Returns the
  /// number of rows; later reads of that section come from the cache.
  Future<int> preload(
    ContentSection section, {
    void Function(int received, int total)? onBytes,
  });

  /// Drop cached catalogue data (the "Refresh Content" settings row).
  Future<void> invalidate();
}

abstract interface class LibraryRepository {
  List<FavoriteEntry> favorites(ContentSection? section);
  bool isFavorite(String key);
  Future<void> toggleFavorite(FavoriteEntry entry);

  List<HistoryEntry> history();
  List<HistoryEntry> continueWatching();
  HistoryEntry? historyFor(String key);

  /// Throttled while playing, flushed on stop (spec §31).
  Future<void> recordProgress(
    HistoryEntry entry, {
    required Duration position,
    required Duration duration,
  });

  Future<void> clearHistory();
}

abstract interface class LicenseRepository {
  LicenseVerdict? get current;
  bool get isLicensed;

  Future<LicenseVerdict> verify(String key);
  Future<LicenseVerdict> refresh();
  Future<List<SubscriptionPlan>> plans();
  Future<TrialConfig> trialConfig();
  Future<bool> trialAvailable();
  Future<LicenseVerdict> claimTrial();
  Future<String?> supportWhatsAppNumber();
  Future<void> clear();
}
