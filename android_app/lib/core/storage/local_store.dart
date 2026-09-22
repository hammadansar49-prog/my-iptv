import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../utils/logger.dart';

/// The bulk local store: favorites, history, settings, download records and
/// the cached catalogue. Equivalent to the PC app's `store.json`, minus the
/// credentials (those live in [SecureStore]).
///
/// Writes are debounced (the PC app debounces its own saves by 3s) so a
/// throttled history update while a video plays never blocks on disk.
class LocalStore {
  LocalStore._(this._file, this._data);

  static const _tag = 'LocalStore';
  static const _debounce = Duration(seconds: 2);

  final File _file;
  Map<String, dynamic> _data;
  Timer? _saveTimer;
  bool _disposed = false;

  static Future<LocalStore> open({String name = 'store.json'}) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    Map<String, dynamic> data = {};
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) data = decoded.cast<String, dynamic>();
      }
    } catch (e) {
      // A corrupt store must not brick the app — start fresh and move the bad
      // file aside so it can be inspected.
      Log.e(_tag, 'store unreadable, starting fresh', e);
      try {
        await file.rename('${file.path}.corrupt');
      } catch (_) {}
    }
    return LocalStore._(file, data);
  }

  T? read<T>(String key) {
    final v = _data[key];
    return v is T ? v : null;
  }

  List<Map<String, dynamic>> readList(String key) {
    final v = _data[key];
    if (v is! List) return [];
    return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Map<String, dynamic> readMap(String key) {
    final v = _data[key];
    return v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
  }

  void write(String key, Object? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_debounce, () => unawaited(flush()));
  }

  /// Write immediately. Called on lifecycle pause and before logout.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      await _file.parent.create(recursive: true);
      // Write to a temp file then rename, so a kill mid-write cannot leave a
      // truncated store behind.
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_data), flush: true);
      await tmp.rename(_file.path);
    } catch (e) {
      Log.e(_tag, 'save failed', e);
    }
  }

  Future<void> clear() async {
    _data = {};
    await flush();
  }

  Future<void> dispose() async {
    _disposed = true;
    _saveTimer?.cancel();
    await flush();
  }
}
