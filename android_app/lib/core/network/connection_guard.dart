import 'dart:async';

import '../constants/app_constants.dart';
import '../utils/logger.dart';

/// Which kind of thing is holding the provider connection.
enum ProviderUse { playback, download, probe }

/// A handle to a held provider connection. Releasing it is mandatory — every
/// caller does it from a `finally` or a `dispose`.
class ProviderLease {
  ProviderLease._(this._guard, this.id, this.use, this.label);

  final ConnectionGuard _guard;
  final int id;
  final ProviderUse use;
  final String label;

  bool _released = false;
  bool get isReleased => _released;

  /// Called by the guard when something with higher priority wants the
  /// connection. Downloads set this to stop themselves politely.
  void Function()? onPreempted;

  void release() {
    if (_released) return;
    _released = true;
    _guard._release(this);
  }
}

/// The Flutter counterpart of main.js's `providerHolders` / `holdProvider()` /
/// `yieldProvider()` / `admitSession()`.
///
/// The tested Xtream account allows exactly ONE simultaneous connection.
/// CLAUDE.md calls this locked behaviour: opening a second connection (a
/// probe, a download, a seek) is what made seeks hang on "connecting" and live
/// channels buffer endlessly. Everything that opens a socket to the provider —
/// playback, downloads, stream probes — goes through here.
///
/// Rules:
///  * `maxConnections` comes from the real account (`user_info.max_connections`),
///    not from a guess. It defaults to 1, the safe value.
///  * Playback pre-empts downloads, never the other way round.
///  * After a lease is released, the next acquirer waits
///    [Playback.providerHandoverGap] — the panel has not yet noticed the old
///    socket closed, and asking immediately gets refused.
class ConnectionGuard {
  ConnectionGuard({int maxConnections = 1}) : _maxConnections = maxConnections;

  static const _tag = 'ConnectionGuard';

  int _maxConnections;
  int _nextId = 1;
  DateTime? _lastRelease;

  final List<ProviderLease> _held = [];
  final List<Completer<void>> _waiters = [];

  /// Downloads may run alongside playback (downloads.js `setConcurrent`).
  /// Only meaningful when the account actually has more than one connection.
  bool _allowConcurrentDownloads = false;

  int get maxConnections => _maxConnections;
  bool get isBusy => _held.isNotEmpty;
  bool get hasPlayback => _held.any((l) => l.use == ProviderUse.playback);

  /// Set once after login from `user_info.max_connections`.
  void configure({required int maxConnections, bool? allowConcurrentDownloads}) {
    _maxConnections = maxConnections < 1 ? 1 : maxConnections;
    if (allowConcurrentDownloads != null) {
      _allowConcurrentDownloads = allowConcurrentDownloads;
    }
    Log.i(_tag, 'max=$_maxConnections concurrentDownloads=$_allowConcurrentDownloads');
    _drain();
  }

  set allowConcurrentDownloads(bool value) {
    if (_allowConcurrentDownloads == value) return;
    _allowConcurrentDownloads = value;
    _drain();
  }

  bool get allowConcurrentDownloads =>
      _allowConcurrentDownloads && _maxConnections > 1;

  /// Room for one more connection of [use] right now?
  bool _canAdmit(ProviderUse use) {
    if (_held.length >= _maxConnections) return false;
    if (use != ProviderUse.playback && hasPlayback && !allowConcurrentDownloads) {
      return false;
    }
    return true;
  }

  /// Wait for the provider connection and take it.
  ///
  /// A [ProviderUse.playback] request pre-empts any held download immediately
  /// rather than queueing behind it — the user is waiting.
  Future<ProviderLease> acquire(
    ProviderUse use, {
    String label = '',
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (use == ProviderUse.playback) _preemptLowerPriority();

    while (!_canAdmit(use)) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      try {
        await waiter.future.timeout(timeout);
      } on TimeoutException {
        _waiters.remove(waiter);
        rethrow;
      }
    }

    // The provider needs a beat to notice the previous socket closed.
    final since = _lastRelease;
    if (since != null) {
      final elapsed = DateTime.now().difference(since);
      if (elapsed < Playback.providerHandoverGap) {
        await Future<void>.delayed(Playback.providerHandoverGap - elapsed);
      }
    }

    final lease = ProviderLease._(this, _nextId++, use, label);
    _held.add(lease);
    Log.d(_tag, 'acquired #${lease.id} ${use.name} $label (held=${_held.length})');
    return lease;
  }

  /// Try to take the connection without waiting. Returns null if busy.
  ProviderLease? tryAcquire(ProviderUse use, {String label = ''}) {
    if (!_canAdmit(use)) return null;
    final lease = ProviderLease._(this, _nextId++, use, label);
    _held.add(lease);
    return lease;
  }

  void _preemptLowerPriority() {
    if (allowConcurrentDownloads) return;
    for (final lease in List.of(_held)) {
      if (lease.use == ProviderUse.playback) continue;
      Log.i(_tag, 'pre-empting #${lease.id} ${lease.use.name} for playback');
      final cb = lease.onPreempted;
      lease.release();
      if (cb != null) {
        try {
          cb();
        } catch (e) {
          Log.w(_tag, 'pre-empt callback threw: $e');
        }
      }
    }
  }

  void _release(ProviderLease lease) {
    _held.remove(lease);
    _lastRelease = DateTime.now();
    Log.d(_tag, 'released #${lease.id} ${lease.use.name} (held=${_held.length})');
    _drain();
  }

  void _drain() {
    while (_waiters.isNotEmpty && _held.length < _maxConnections) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) waiter.complete();
      // Only wake one per free slot; the woken waiter re-checks _canAdmit.
      break;
    }
    // Waking one is enough when a single slot freed, but if several slots are
    // free (maxConnections was raised) keep going.
    if (_waiters.isNotEmpty && _held.length + 1 < _maxConnections) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  /// Run [body] holding the connection, releasing it however [body] ends.
  Future<T> withConnection<T>(
    ProviderUse use,
    Future<T> Function(ProviderLease lease) body, {
    String label = '',
  }) async {
    final lease = await acquire(use, label: label);
    try {
      return await body(lease);
    } finally {
      lease.release();
    }
  }

  void dispose() {
    for (final lease in List.of(_held)) {
      lease.release();
    }
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }
}
