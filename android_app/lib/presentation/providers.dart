import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/connection_guard.dart';
import '../core/network/http_client.dart';
import '../core/security/device_identity.dart';
import '../core/storage/local_store.dart';
import '../core/storage/secure_store.dart';
import '../data/api/rtdb_api.dart';
import '../data/models/account.dart';
import '../data/models/content.dart';
import '../data/models/library.dart';
import '../data/repositories/account_summary_store.dart';
import '../data/repositories/auth_repository_impl.dart';
import '../data/repositories/content_repository_impl.dart';
import '../data/repositories/library_repository_impl.dart';
import '../data/repositories/license_repository_impl.dart';
import '../domain/repositories/repositories.dart';
import '../services/download/download_manager.dart';
import 'security/app_lock_controller.dart';

/// Composition root. Everything the app needs is wired here once; nothing
/// constructs its own dependencies (spec §5/§6).

// ---- Bootstrap singletons --------------------------------------------------

/// Resolved during the splash screen, before anything else reads it.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider must be overridden'),
);

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final deviceIdentityProvider = Provider<DeviceIdentity>((ref) => DeviceIdentity());

final appLockProvider =
    StateNotifierProvider<AppLockController, String?>((ref) {
  return AppLockController(ref.watch(secureStoreProvider));
});

/// Set while a tab shows video fullscreen in place (EPG), so the shell
/// hides its floating nav bar over the picture.
final shellNavHiddenProvider = StateProvider<bool>((ref) => false);

/// True on Android TV. Drives every adaptive-layout decision (spec §36).
final isTvProvider = Provider<bool>((ref) => false);

final connectionGuardProvider = Provider<ConnectionGuard>((ref) {
  final guard = ConnectionGuard();
  ref.onDispose(guard.dispose);
  return guard;
});

final httpClientProvider = Provider<HttpClient>((ref) {
  final client = HttpClient();
  ref.onDispose(client.close);
  return client;
});

final rtdbApiProvider = Provider<RtdbApi>((ref) {
  final api = RtdbApi();
  ref.onDispose(api.close);
  return api;
});

// ---- Repositories ----------------------------------------------------------

final authRepositoryProvider = Provider<AuthRepositoryImpl>((ref) {
  return AuthRepositoryImpl(
    secureStore: ref.watch(secureStoreProvider),
    http: ref.watch(httpClientProvider),
    guard: ref.watch(connectionGuardProvider),
  );
});

final licenseRepositoryProvider = Provider<LicenseRepositoryImpl>((ref) {
  return LicenseRepositoryImpl(
    api: ref.watch(rtdbApiProvider),
    store: ref.watch(secureStoreProvider),
    identity: ref.watch(deviceIdentityProvider),
  );
});

final libraryRepositoryProvider = Provider<LibraryRepositoryImpl>((ref) {
  final repo = LibraryRepositoryImpl(store: ref.watch(localStoreProvider));
  ref.onDispose(repo.dispose);
  return repo;
});

final accountSummaryStoreProvider = Provider<AccountSummaryStore>((ref) {
  final store = AccountSummaryStore(store: ref.watch(localStoreProvider));
  ref.onDispose(store.dispose);
  return store;
});

/// Bumped whenever a summary is recorded, so account cards refresh.
final accountSummaryRevisionProvider = StreamProvider<int>((ref) {
  final store = ref.watch(accountSummaryStoreProvider);
  var n = 0;
  return store.changes.map((_) => ++n);
});

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager(
    store: ref.watch(localStoreProvider),
    guard: ref.watch(connectionGuardProvider),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// The signed-in session. Null until login succeeds; set by [AuthController].
final sessionProvider = StateProvider<XtreamSession?>((ref) => null);

/// Content repository bound to the active account. Rebuilt on sign-in/out,
/// which also throws away the cached catalogue — exactly what we want.
final contentRepositoryProvider = Provider<ContentRepository?>((ref) {
  // Depend on the session so a new login produces a new repository.
  final session = ref.watch(sessionProvider);
  if (session == null) return null;
  final auth = ref.watch(authRepositoryProvider);
  final api = auth.api;
  if (api == null) return null;
  return ContentRepositoryImpl(api: api);
});

/// Convenience: throws a clear error if read before login rather than
/// returning null into widget code.
ContentRepository requireContent(Ref ref) {
  final repo = ref.read(contentRepositoryProvider);
  if (repo == null) {
    throw StateError('Content requested before sign-in');
  }
  return repo;
}

// ---- Catalogue ------------------------------------------------------------

final categoriesProvider =
    FutureProvider.family<List<Category>, ContentSection>((ref, section) async {
  final repo = ref.watch(contentRepositoryProvider);
  if (repo == null) return const [];
  return repo.categories(section);
});

/// Currently selected category per section. Empty string means "All".
final selectedCategoryProvider =
    StateProvider.family<String, ContentSection>((ref, section) => '');

final liveChannelsProvider =
    FutureProvider.family<List<LiveChannel>, String>((ref, categoryId) async {
  final repo = ref.watch(contentRepositoryProvider);
  if (repo == null) return const [];
  return repo.liveChannels(categoryId: categoryId);
});

final moviesProvider =
    FutureProvider.family<List<Movie>, String>((ref, categoryId) async {
  final repo = ref.watch(contentRepositoryProvider);
  if (repo == null) return const [];
  return repo.movies(categoryId: categoryId);
});

final seriesProvider =
    FutureProvider.family<List<Series>, String>((ref, categoryId) async {
  final repo = ref.watch(contentRepositoryProvider);
  if (repo == null) return const [];
  return repo.seriesList(categoryId: categoryId);
});

final movieDetailProvider =
    FutureProvider.family<MovieDetail?, Movie>((ref, movie) async {
  final repo = ref.watch(contentRepositoryProvider);
  return repo?.movieDetail(movie);
});

final seriesDetailProvider =
    FutureProvider.family<SeriesDetail?, Series>((ref, series) async {
  final repo = ref.watch(contentRepositoryProvider);
  return repo?.seriesDetail(series);
});

// ---- Library (favorites / history) ----------------------------------------

/// Rebuilds whenever the library repository reports a change, so favorite
/// hearts and Continue Watching stay in sync without polling.
final libraryRevisionProvider = StreamProvider<int>((ref) {
  final repo = ref.watch(libraryRepositoryProvider);
  var n = 0;
  return repo.changes.map((_) => ++n);
});

final favoritesProvider =
    Provider.family<List<FavoriteEntry>, ContentSection?>((ref, section) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryRepositoryProvider).favorites(section);
});

final continueWatchingProvider = Provider<List<HistoryEntry>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryRepositoryProvider).continueWatching();
});

final historyProvider = Provider<List<HistoryEntry>>((ref) {
  ref.watch(libraryRevisionProvider);
  return ref.watch(libraryRepositoryProvider).history();
});

// ---- Downloads -------------------------------------------------------------

final downloadsProvider = StreamProvider<List<DownloadItem>>((ref) {
  final manager = ref.watch(downloadManagerProvider);
  // Seed with the current list so the screen is never briefly empty.
  return manager.changes.asBroadcastStream();
});

final downloadListProvider = Provider<List<DownloadItem>>((ref) {
  final async = ref.watch(downloadsProvider);
  return async.valueOrNull ?? ref.watch(downloadManagerProvider).items;
});
