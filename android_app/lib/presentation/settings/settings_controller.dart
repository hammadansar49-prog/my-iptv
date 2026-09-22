import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_store.dart';
import '../providers.dart';

/// User-facing preferences. Deliberately short — spec §35 says not to add
/// settings for the sake of having more of them. Every option here changes
/// real behaviour.
class AppSettings {
  const AppSettings({
    this.autoPlayNextEpisode = true,
    this.downloadWhileWatching = true,
    this.preferredLiveExtension = 'm3u8',
    this.preferredAspectRatio = 'contain',
  });

  /// Spec §32: when off, an episode ending does not start the next one.
  final bool autoPlayNextEpisode;

  /// The PC app's Settings → Downloads toggle (default on). Only has any
  /// effect on an account with more than one connection.
  final bool downloadWhileWatching;

  /// Some panels serve `.ts` far more reliably than `.m3u8`.
  final String preferredLiveExtension;

  final String preferredAspectRatio;

  AppSettings copyWith({
    bool? autoPlayNextEpisode,
    bool? downloadWhileWatching,
    String? preferredLiveExtension,
    String? preferredAspectRatio,
  }) =>
      AppSettings(
        autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
        downloadWhileWatching:
            downloadWhileWatching ?? this.downloadWhileWatching,
        preferredLiveExtension:
            preferredLiveExtension ?? this.preferredLiveExtension,
        preferredAspectRatio:
            preferredAspectRatio ?? this.preferredAspectRatio,
      );

  Map<String, dynamic> toJson() => {
        'autoPlayNextEpisode': autoPlayNextEpisode,
        'downloadWhileWatching': downloadWhileWatching,
        'preferredLiveExtension': preferredLiveExtension,
        'preferredAspectRatio': preferredAspectRatio,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        autoPlayNextEpisode: j['autoPlayNextEpisode'] as bool? ?? true,
        downloadWhileWatching: j['downloadWhileWatching'] as bool? ?? true,
        preferredLiveExtension:
            j['preferredLiveExtension'] as String? ?? 'm3u8',
        preferredAspectRatio: j['preferredAspectRatio'] as String? ?? 'contain',
      );
}

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController(this._ref, LocalStore store)
      : _store = store,
        super(AppSettings.fromJson(store.readMap(_key))) {
    // Apply the persisted download toggle to the guard at startup, so the
    // preference is live before the first download is considered.
    _applyToGuard();
  }

  static const _key = 'settings';

  final Ref _ref;
  final LocalStore _store;

  void _applyToGuard() {
    _ref.read(connectionGuardProvider).allowConcurrentDownloads =
        state.downloadWhileWatching;
  }

  void _persist() {
    _store.write(_key, state.toJson());
  }

  void setAutoPlayNextEpisode(bool value) {
    state = state.copyWith(autoPlayNextEpisode: value);
    _persist();
  }

  void setDownloadWhileWatching(bool value) {
    state = state.copyWith(downloadWhileWatching: value);
    _applyToGuard();
    _persist();
  }

  void setPreferredLiveExtension(String value) {
    state = state.copyWith(preferredLiveExtension: value);
    _persist();
  }

  void setPreferredAspectRatio(String value) {
    state = state.copyWith(preferredAspectRatio: value);
    _persist();
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsController, AppSettings>((ref) {
  return SettingsController(ref, ref.watch(localStoreProvider));
});
