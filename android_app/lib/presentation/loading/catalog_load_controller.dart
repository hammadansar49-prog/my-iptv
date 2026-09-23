import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_error.dart';
import '../../core/utils/logger.dart';
import '../../data/models/content.dart';
import '../auth/auth_controller.dart';
import '../providers.dart';

/// The five rows on the loading screen, in display order.
enum LoadStage { movies, series, live, downloads, library }

enum StageStatus { pending, running, done, failed }

class StageState {
  const StageState({
    this.status = StageStatus.pending,
    this.fraction = 0,
    this.count,
  });

  final StageStatus status;

  /// 0..1 for this stage alone.
  final double fraction;

  /// Rows loaded, once known (movies/series/live only).
  final int? count;

  bool get isDone => status == StageStatus.done;
}

class CatalogLoadState {
  const CatalogLoadState({
    this.stages = const {},
    this.progress = 0,
    this.error,
    this.finished = false,
  });

  final Map<LoadStage, StageState> stages;

  /// 0..1 across everything, weighted by how much each stage actually has
  /// to download.
  final double progress;
  final AppError? error;
  final bool finished;

  StageState of(LoadStage s) => stages[s] ?? const StageState();

  /// The row to highlight: the first one, in display order, not yet done.
  LoadStage? get current {
    for (final s in LoadStage.values) {
      if (!of(s).isDone) return s;
    }
    return null;
  }

  int get streamTotal =>
      (of(LoadStage.movies).count ?? 0) +
      (of(LoadStage.series).count ?? 0) +
      (of(LoadStage.live).count ?? 0);
}

/// Loads the whole catalogue up front after sign-in, so Home, Movies, Series
/// and Live TV open instantly with posters instead of each spinning on its
/// own fetch.
///
/// Everything reported here is real: the three catalogue downloads run in
/// parallel and their progress comes from Dio's received-bytes callback;
/// a stage turns "done" only when its rows are parsed and cached in the
/// ContentRepository. Panels normally send these gzipped with no
/// Content-Length, so a byte total is usually unknown — progress is then
/// measured against the size this account's catalogue had last time
/// (remembered per account), or a generous default on first load, and held
/// just short of full until the data is genuinely in.
class CatalogLoadController extends StateNotifier<CatalogLoadState> {
  CatalogLoadController(this._ref) : super(const CatalogLoadState());

  final Ref _ref;
  static const _tag = 'CatalogLoad';
  static const _sizesKey = 'catalogue_bytes';

  /// First-load guesses when this account has never been loaded before.
  static const _defaultBytes = {
    LoadStage.movies: 25000000,
    LoadStage.series: 6000000,
    LoadStage.live: 5000000,
  };

  /// Share of a network stage spent downloading; the rest is the
  /// background-isolate parse, which has no finer-grained signal.
  static const _downloadShare = 0.9;

  final Map<LoadStage, StageState> _stages = {};
  final Map<LoadStage, int> _received = {};
  Map<LoadStage, double> _weights = {};
  Timer? _emit;
  bool _running = false;

  Future<void> run() async {
    if (_running) return;
    _running = true;
    final sw = Stopwatch()..start();

    final repo = _ref.read(contentRepositoryProvider);
    final accountId = _ref.read(authControllerProvider).account?.id;
    if (repo == null || accountId == null) {
      _running = false;
      state = const CatalogLoadState(
        error: AppError(
          AppErrorKind.authentication,
          'You are not signed in. Please add your Xtream account again.',
        ),
      );
      return;
    }

    final estimate = _estimates(accountId);
    final networkTotal = estimate.values.fold<int>(0, (a, b) => a + b);
    _weights = {
      for (final e in estimate.entries) e.key: 0.92 * e.value / networkTotal,
      LoadStage.downloads: 0.02,
      LoadStage.library: 0.06,
    };
    for (final s in LoadStage.values) {
      final prev = _stages[s];
      if (prev == null || !prev.isDone) {
        _stages[s] = const StageState(status: StageStatus.running);
      }
    }
    state = CatalogLoadState(stages: Map.of(_stages), progress: _overall());

    Future<void> network(LoadStage stage, ContentSection section) async {
      if (_stages[stage]!.isDone) return;
      final est = estimate[stage]!;
      final count = await repo.preload(section, onBytes: (received, total) {
        _received[stage] = received;
        final f = total > 0
            ? received / total
            : (received / est).clamp(0.0, 0.97);
        _stages[stage] = StageState(
          status: StageStatus.running,
          fraction: f * _downloadShare,
        );
        _scheduleEmit();
      });
      _stages[stage] = StageState(
        status: StageStatus.done,
        fraction: 1,
        count: count,
      );
      _scheduleEmit();
    }

    Future<void> downloads() async {
      if (_stages[LoadStage.downloads]!.isDone) return;
      // The download manager restores its saved queue at startup; this just
      // confirms it is up (no network).
      _ref.read(downloadManagerProvider).items;
      _stages[LoadStage.downloads] =
          const StageState(status: StageStatus.done, fraction: 1);
      _scheduleEmit();
    }

    Future<void> library() async {
      if (_stages[LoadStage.library]!.isDone) return;
      // Category lists for all three sections (small requests), so the
      // category chips on Movies/Series/Live TV are ready too.
      var done = 0;
      await Future.wait(ContentSection.values.map((section) async {
        try {
          await repo.categories(section);
        } catch (e) {
          // Non-fatal: each screen fetches its own categories on open.
          Log.w(_tag, 'categories(${section.name}) failed: $e');
        }
        done++;
        _stages[LoadStage.library] = StageState(
          status: StageStatus.running,
          fraction: done / ContentSection.values.length,
        );
        _scheduleEmit();
      }));
      _ref.read(libraryRepositoryProvider).favorites(null);
      _stages[LoadStage.library] =
          const StageState(status: StageStatus.done, fraction: 1);
      _scheduleEmit();
    }

    Future<void> guarded(LoadStage stage, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        _stages[stage] = StageState(
          status: StageStatus.failed,
          fraction: _stages[stage]?.fraction ?? 0,
        );
        rethrow;
      }
    }

    try {
      await Future.wait([
        guarded(LoadStage.movies,
            () => network(LoadStage.movies, ContentSection.movies)),
        guarded(LoadStage.series,
            () => network(LoadStage.series, ContentSection.series)),
        guarded(LoadStage.live,
            () => network(LoadStage.live, ContentSection.live)),
        guarded(LoadStage.downloads, downloads),
        guarded(LoadStage.library, library),
      ]);
    } catch (e) {
      Log.w(_tag, 'load failed after ${sw.elapsedMilliseconds}ms: $e');
      _emit?.cancel();
      _running = false;
      if (!mounted) return;
      state = CatalogLoadState(
        stages: Map.of(_stages),
        progress: _overall(),
        error: e is AppError ? e : AppError.fromTransport(e),
      );
      return;
    }

    _emit?.cancel();
    _running = false;
    if (!mounted) return;
    _remember(accountId);
    final done = CatalogLoadState(
      stages: Map.of(_stages),
      progress: 1,
      finished: true,
    );
    _recordSummary(accountId, done.streamTotal);
    Log.i(_tag,
        'catalogue ready in ${sw.elapsedMilliseconds}ms: ${done.streamTotal} streams');
    state = done;
  }

  /// Progress callbacks arrive per network chunk (thousands for a 27MB
  /// response); rebuilding the screen for each would waste the UI thread
  /// the loading screen exists to keep free. Coalesce to ~30fps.
  void _scheduleEmit() {
    if (_emit?.isActive ?? false) return;
    _emit = Timer(const Duration(milliseconds: 33), () {
      if (!mounted) return;
      state = CatalogLoadState(stages: Map.of(_stages), progress: _overall());
    });
  }

  double _overall() {
    var p = 0.0;
    for (final s in LoadStage.values) {
      p += (_weights[s] ?? 0) * (_stages[s]?.fraction ?? 0);
    }
    return p.clamp(0.0, 1.0);
  }

  Map<LoadStage, int> _estimates(String accountId) {
    final saved = _ref.read(localStoreProvider).readMap(_sizesKey)[accountId];
    final out = Map<LoadStage, int>.of(_defaultBytes);
    if (saved is Map) {
      for (final s in _defaultBytes.keys) {
        final v = saved[s.name];
        if (v is int && v > 0) out[s] = v;
      }
    }
    return out;
  }

  /// Keep this account's real catalogue sizes so the next load's progress
  /// bar is accurate from the first byte.
  void _remember(String accountId) {
    if (_received.isEmpty) return;
    final store = _ref.read(localStoreProvider);
    final all = store.readMap(_sizesKey);
    final mine = Map<String, dynamic>.of(
      all[accountId] is Map
          ? (all[accountId] as Map).cast<String, dynamic>()
          : const {},
    );
    for (final e in _received.entries) {
      mine[e.key.name] = e.value;
    }
    store.write(_sizesKey, {...all, accountId: mine});
  }

  void _recordSummary(String accountId, int streams) {
    final session = _ref.read(sessionProvider);
    _ref.read(accountSummaryStoreProvider).record(
          accountId,
          (existing) => existing.copyWith(
            username: session?.userInfo.username,
            status: session?.userInfo.status,
            expiresAt: session?.userInfo.expiresAt,
            streamCount: streams,
          ),
        );
  }

  @override
  void dispose() {
    _emit?.cancel();
    super.dispose();
  }
}

final catalogLoadProvider = StateNotifierProvider.autoDispose<
    CatalogLoadController, CatalogLoadState>(
  (ref) => CatalogLoadController(ref),
);
