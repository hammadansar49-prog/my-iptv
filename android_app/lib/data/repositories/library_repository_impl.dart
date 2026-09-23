import 'dart:async';

import '../../core/constants/app_constants.dart';
import '../../core/storage/local_store.dart';
import '../../domain/repositories/repositories.dart';
import '../models/content.dart';
import '../models/library.dart';

/// Favorites + watch history, local only (AUDIT.md §4).
class LibraryRepositoryImpl implements LibraryRepository {
  LibraryRepositoryImpl({required LocalStore store}) : _store = store {
    _favorites = _store.readList(_kFavorites).map(FavoriteEntry.fromJson).toList();
    _history = _store.readList(_kHistory).map(HistoryEntry.fromJson).toList();
  }

  static const _kFavorites = 'favorites';
  static const _kHistory = 'history';

  final LocalStore _store;
  late List<FavoriteEntry> _favorites;
  late List<HistoryEntry> _history;

  /// Notifies listeners (Riverpod providers) that the lists changed.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  /// Last time each history key was persisted, for throttling (spec §31).
  final Map<String, DateTime> _lastWrite = {};

  @override
  List<FavoriteEntry> favorites(ContentSection? section) => section == null
      ? List.unmodifiable(_favorites)
      : List.unmodifiable(_favorites.where((f) => f.section == section));

  @override
  bool isFavorite(String key) => _favorites.any((f) => f.key == key);

  @override
  Future<void> toggleFavorite(FavoriteEntry entry) async {
    final idx = _favorites.indexWhere((f) => f.key == entry.key);
    if (idx >= 0) {
      _favorites.removeAt(idx);
    } else {
      _favorites.insert(0, entry);
    }
    _persistFavorites();
    _changes.add(null);
  }

  void _persistFavorites() =>
      _store.write(_kFavorites, _favorites.map((f) => f.toJson()).toList());

  @override
  List<HistoryEntry> history() => List.unmodifiable(_history);

  @override
  List<HistoryEntry> continueWatching() =>
      List.unmodifiable(_history.where((h) => h.isContinueWatching));

  @override
  HistoryEntry? historyFor(String key) {
    for (final h in _history) {
      if (h.key == key) return h;
    }
    return null;
  }

  @override
  Future<void> recordProgress(
    HistoryEntry entry, {
    required Duration position,
    required Duration duration,
  }) async {
    final updated = entry.copyWith(
      resumeAt: entry.isLive ? Duration.zero : position,
      duration: entry.isLive ? Duration.zero : duration,
      updatedAt: DateTime.now(),
    );

    // Most-recent-first, deduped by key, capped — exactly upsertHistory().
    _history.removeWhere((h) => h.key == updated.key);
    _history.insert(0, updated);
    if (_history.length > Limits.historyEntries) {
      _history = _history.sublist(0, Limits.historyEntries);
    }
    _changes.add(null);

    // Throttle disk writes: this is called on every player tick.
    final last = _lastWrite[updated.key];
    final now = DateTime.now();
    if (last != null && now.difference(last) < Playback.historyThrottle) return;
    _lastWrite[updated.key] = now;
    _persistHistory();
  }

  /// Called once when playback stops, bypassing the throttle so the final
  /// position is never lost.
  Future<void> flushProgress() async {
    _persistHistory();
    await _store.flush();
  }

  void _persistHistory() =>
      _store.write(_kHistory, _history.map((h) => h.toJson()).toList());

  @override
  Future<void> removeHistory(String key) async {
    final before = _history.length;
    _history.removeWhere((h) => h.key == key);
    if (_history.length == before) return;
    _lastWrite.remove(key);
    // Flushed immediately: a removal the user asked for must not come back
    // because the app was killed before the next throttled write.
    _persistHistory();
    await _store.flush();
    _changes.add(null);
  }

  @override
  Future<void> clearHistory() async {
    _history = [];
    _lastWrite.clear();
    _persistHistory();
    await _store.flush();
    _changes.add(null);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
