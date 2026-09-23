import 'dart:async';

import '../../core/storage/local_store.dart';
import '../models/account_summary.dart';

/// Per-account cached facts for the Accounts screen. Plain local storage —
/// this is display convenience, not authoritative state, so it lives in
/// [LocalStore] rather than the keystore (nothing here is a credential).
class AccountSummaryStore {
  AccountSummaryStore({required LocalStore store}) : _store = store {
    final raw = _store.readMap(_key);
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is Map) {
        _summaries[entry.key] =
            AccountSummary.fromJson(value.cast<String, dynamic>());
      }
    }
  }

  static const _key = 'account_summaries';

  final LocalStore _store;
  final Map<String, AccountSummary> _summaries = {};

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  AccountSummary? of(String accountId) => _summaries[accountId];

  void record(String accountId, AccountSummary Function(AccountSummary) update) {
    final existing =
        _summaries[accountId] ?? AccountSummary(accountId: accountId);
    final next = update(existing);
    // Skip the write when nothing actually changed — this is called from a
    // widget build path, and a needless write would wake the debounce timer
    // on every rebuild.
    if (existing.username == next.username &&
        existing.status == next.status &&
        existing.streamCount == next.streamCount &&
        existing.expiresAt == next.expiresAt) {
      return;
    }
    _summaries[accountId] = next;
    _persist();
    if (!_changes.isClosed) _changes.add(null);
  }

  void remove(String accountId) {
    if (_summaries.remove(accountId) == null) return;
    _persist();
    if (!_changes.isClosed) _changes.add(null);
  }

  void _persist() {
    _store.write(
      _key,
      _summaries.map((id, summary) => MapEntry(id, summary.toJson())),
    );
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
