import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Stream ids the user pinned to the top of the EPG, in pin order.
///
/// Stored as a plain list of ints in [LocalStore] so pins survive restarts
/// without a schema of their own.
class EpgPinsNotifier extends StateNotifier<List<int>> {
  EpgPinsNotifier(this._ref) : super(_load(_ref));

  static const storeKey = 'epg_pinned_channels';

  final Ref _ref;

  static List<int> _load(Ref ref) {
    final raw = ref.read(localStoreProvider).read<List>(storeKey) ?? const [];
    // JSON round-trips may yield num; tolerate anything numeric.
    return raw.whereType<num>().map((n) => n.toInt()).toList();
  }

  bool isPinned(int streamId) => state.contains(streamId);

  void pin(int streamId) {
    if (state.contains(streamId)) return;
    _save([...state, streamId]);
  }

  void unpin(int streamId) {
    _save(state.where((id) => id != streamId).toList());
  }

  void _save(List<int> next) {
    state = next;
    _ref.read(localStoreProvider).write(storeKey, next);
  }
}

final epgPinsProvider = StateNotifierProvider<EpgPinsNotifier, List<int>>(
  EpgPinsNotifier.new,
);
