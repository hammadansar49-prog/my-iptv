import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Professional two-tier cache (Memory L1 + Disk L2) with LRU eviction,
/// TTL expiration, and size limits — the same pattern Netflix/Spotify use.

// ---------------------------------------------------------------------------
// MemoryCache — LRU in-memory cache with configurable TTL and max entries.
// ---------------------------------------------------------------------------

class _CacheEntry<T> {
  final T value;
  DateTime lastAccessed;
  final DateTime expiresAt;

  _CacheEntry(this.value, this.expiresAt) : lastAccessed = DateTime.now();

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class MemoryCache<T> {
  final int maxSize;
  final Duration ttl;

  /// LinkedHashMap in insertion-order; access moves entry to end (MRU).
  final LinkedHashMap<String, _CacheEntry<T>> _map = LinkedHashMap();

  MemoryCache({this.maxSize = 120, this.ttl = const Duration(minutes: 10)});

  /// Returns the cached value or `null` on miss / expiry.
  T? get(String key) {
    final entry = _map[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _map.remove(key);
      _statsMisses++;
      return null;
    }
    // Move to end = most-recently-used
    _map.remove(key);
    _map[key] = entry;
    _statsHits++;
    return entry.value;
  }

  bool containsKey(String key) {
    final entry = _map[key];
    if (entry == null) return false;
    if (entry.isExpired) {
      _map.remove(key);
      return false;
    }
    return true;
  }

  void put(String key, T value, {Duration? overrideTtl}) {
    _map.remove(key); // re-insert at end
    while (_map.length >= maxSize) {
      _map.remove(_map.keys.first); // evict LRU
    }
    _map[key] = _CacheEntry(value, DateTime.now().add(overrideTtl ?? ttl));
  }

  void remove(String key) => _map.remove(key);

  void clear() => _map.clear();

  /// Remove all expired entries.
  void prune() => _map.removeWhere((_, e) => e.isExpired);

  int get length => _map.length;
  bool get isEmpty => _map.isEmpty;

  // --- Stats ---
  int _statsHits = 0;
  int _statsMisses = 0;
  int get hits => _statsHits;
  int get misses => _statsMisses;
  double get hitRate => (_statsHits + _statsMisses) == 0
      ? 0
      : _statsHits / (_statsHits + _statsMisses);
  void resetStats() {
    _statsHits = 0;
    _statsMisses = 0;
  }
}

// ---------------------------------------------------------------------------
// DiskCache — File-based persistent cache with TTL and max size (LRU).
// ---------------------------------------------------------------------------

class DiskCache {
  final Directory directory;
  final int maxSizeBytes;
  final Duration defaultTtl;

  DiskCache({
    required this.directory,
    this.maxSizeBytes = 50 * 1024 * 1024, // 50 MB
    this.defaultTtl = const Duration(hours: 24),
  });

  File _fileFor(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return File('${directory.path}/dc_$safe');
  }

  Future<Uint8List?> get(String key, {Duration? ttl}) async {
    final file = _fileFor(key);
    try {
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final maxAge = ttl ?? defaultTtl;
      if (DateTime.now().difference(stat.modified) > maxAge) {
        await file.delete().catchError((_) => file);
        return null;
      }
      // Touch for LRU ordering
      await file.setLastModified(DateTime.now());
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> put(String key, Uint8List data) async {
    try {
      await directory.create(recursive: true);
      final file = _fileFor(key);
      await file.writeAsBytes(data, flush: false);
      await _enforceSizeLimit();
    } catch (_) {}
  }

  Future<void> remove(String key) async {
    final file = _fileFor(key);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      if (!await directory.exists()) return;
      await for (final f in directory.list()) {
        if (f is File && f.path.contains('dc_')) {
          await f.delete().catchError((_) => f);
        }
      }
    } catch (_) {}
  }

  /// Evict oldest files until total size is under 80% of [maxSizeBytes].
  Future<void> _enforceSizeLimit() async {
    try {
      if (!await directory.exists()) return;
      final files = <_DiskEntry>[];
      int totalSize = 0;
      await for (final f in directory.list()) {
        if (f is File && f.path.contains('dc_')) {
          final stat = await f.stat();
          files.add(_DiskEntry(f, stat.size, stat.modified));
          totalSize += stat.size;
        }
      }
      if (totalSize <= maxSizeBytes) return;
      // Sort oldest first (LRU)
      files.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in files) {
        if (totalSize <= maxSizeBytes * 0.8) break;
        totalSize -= entry.size;
        await entry.file.delete().catchError((_) => entry.file);
      }
    } catch (_) {}
  }

  Future<int> get currentSizeBytes async {
    int total = 0;
    try {
      if (!await directory.exists()) return 0;
      await for (final f in directory.list()) {
        if (f is File && f.path.contains('dc_')) {
          final stat = await f.stat();
          total += stat.size;
        }
      }
    } catch (_) {}
    return total;
  }
}

class _DiskEntry {
  final File file;
  final int size;
  final DateTime modified;
  _DiskEntry(this.file, this.size, this.modified);
}

// ---------------------------------------------------------------------------
// CacheManager — Unified two-tier cache used throughout the app.
// ---------------------------------------------------------------------------

class CacheManager {
  /// Category lists (small, changes rarely).
  late final MemoryCache<List<dynamic>> categories;

  /// Item lists (large, changes rarely — the big one is ~27 MB movies).
  late final MemoryCache<List<dynamic>> items;

  /// Generic metadata cache (series info, EPG, etc.).
  late final MemoryCache<dynamic> meta;

  /// Disk cache for raw bytes (catalog JSON, etc.).
  late final DiskCache disk;

  CacheManager({required Directory cacheDir})
      : disk = DiskCache(
          directory: cacheDir,
          maxSizeBytes: 50 * 1024 * 1024,
          defaultTtl: const Duration(hours: 1),
        ) {
    categories = MemoryCache<List<dynamic>>(
      maxSize: 60,
      ttl: const Duration(hours: 1),
    );
    items = MemoryCache<List<dynamic>>(
      maxSize: 30,
      ttl: const Duration(minutes: 10),
    );
    meta = MemoryCache<dynamic>(
      maxSize: 100,
      ttl: const Duration(minutes: 30),
    );
  }

  /// Clear everything (memory + disk). Called on logout.
  Future<void> clearAll() async {
    categories.clear();
    items.clear();
    meta.clear();
    await disk.clear();
  }

  /// Clear only memory caches (called on force-refresh).
  void clearMemory() {
    categories.clear();
    items.clear();
    meta.clear();
  }

  /// Drop expired entries from all memory caches.
  void prune() {
    categories.prune();
    items.prune();
    meta.prune();
  }

  /// Human-readable stats for debugging.
  Map<String, dynamic> get stats => {
        'mem_categories': categories.length,
        'mem_items': items.length,
        'mem_meta': meta.length,
        'cat_hit_rate': '${(categories.hitRate * 100).toStringAsFixed(1)}%',
        'item_hit_rate': '${(items.hitRate * 100).toStringAsFixed(1)}%',
        'meta_hit_rate': '${(meta.hitRate * 100).toStringAsFixed(1)}%',
      };
}
