import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/errors/app_error.dart';
import '../providers.dart';
import 'custom_models.dart';

/// LocalStore keys. New keys only — no existing key is read or changed.
const _channelsKey = 'customChannels';
const _playlistsKey = 'customPlaylists';

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

/// Single channels: small, so they live straight in LocalStore.
class CustomChannelsNotifier extends Notifier<List<CustomChannel>> {
  @override
  List<CustomChannel> build() => ref
      .read(localStoreProvider)
      .readList(_channelsKey)
      .map(CustomChannel.fromJson)
      .whereType<CustomChannel>()
      .toList();

  void _save(List<CustomChannel> list) {
    state = list;
    ref
        .read(localStoreProvider)
        .write(_channelsKey, list.map((c) => c.toJson()).toList());
  }

  void upsert({String? id, required String name, required String url, String? logo}) {
    final ch = CustomChannel(
      id: id ?? _newId(),
      name: name,
      url: url,
      logo: logo,
    );
    final list = [...state];
    final i = list.indexWhere((c) => c.id == ch.id);
    if (i >= 0) {
      list[i] = ch;
    } else {
      list.add(ch);
    }
    _save(list);
  }

  void remove(String id) => _save(state.where((c) => c.id != id).toList());
}

final customChannelsProvider =
    NotifierProvider<CustomChannelsNotifier, List<CustomChannel>>(
        CustomChannelsNotifier.new);

/// M3U playlists. Metadata in LocalStore; the raw text in
/// `<appSupport>/m3u/<id>.m3u`, because LocalStore rewrites its whole JSON
/// on every save and a 20 MB playlist in there would make every history
/// update on the whole app slow.
class CustomPlaylistsNotifier extends Notifier<List<M3uPlaylist>> {
  @override
  List<M3uPlaylist> build() => ref
      .read(localStoreProvider)
      .readList(_playlistsKey)
      .map(M3uPlaylist.fromJson)
      .whereType<M3uPlaylist>()
      .toList();

  void _save(List<M3uPlaylist> list) {
    state = list;
    ref
        .read(localStoreProvider)
        .write(_playlistsKey, list.map((p) => p.toJson()).toList());
  }

  static Future<File> _file(String id) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}m3u'
        '${Platform.pathSeparator}$id.m3u');
  }

  M3uPlaylist? byId(String id) {
    for (final p in state) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Downloads, validates and caches. Throws [AppError] on failure; nothing
  /// is saved unless the download produced at least one entry.
  Future<M3uPlaylist> add({required String name, required String url}) async {
    final id = _newId();
    final entries = await _download(id, url);
    final p = M3uPlaylist(
      id: id,
      name: name,
      url: url,
      lastRefresh: DateTime.now(),
      entryCount: entries.length,
    );
    _save([...state, p]);
    return p;
  }

  Future<List<M3uEntry>> refresh(String id) async {
    final p = byId(id);
    if (p == null) return const [];
    final entries = await _download(id, p.url);
    _save([
      for (final x in state)
        x.id == id
            ? x.copyWith(lastRefresh: DateTime.now(), entryCount: entries.length)
            : x,
    ]);
    return entries;
  }

  Future<List<M3uEntry>> _download(String id, String url) async {
    final text = await ref.read(httpClientProvider).getText(url);
    // Parsing 20k+ lines on the UI isolate drops frames; do it off-thread.
    final entries = await compute(parseM3u, text);
    if (entries.isEmpty) {
      throw const AppError(
        AppErrorKind.parsing,
        'That link did not return an M3U playlist with any channels.',
      );
    }
    final f = await _file(id);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
    return entries;
  }

  /// Reads the cached copy. Returns null when there is no cache (e.g. the
  /// file was cleared), so the caller can fall back to a refresh.
  Future<List<M3uEntry>?> loadCached(String id) async {
    final f = await _file(id);
    if (!await f.exists()) return null;
    final text = await f.readAsString();
    return compute(parseM3u, text);
  }

  void rename(String id, String name) => _save([
        for (final x in state) x.id == id ? x.copyWith(name: name) : x,
      ]);

  Future<void> remove(String id) async {
    _save(state.where((p) => p.id != id).toList());
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // A leftover cache file is harmless.
    }
  }
}

final customPlaylistsProvider =
    NotifierProvider<CustomPlaylistsNotifier, List<M3uPlaylist>>(
        CustomPlaylistsNotifier.new);
