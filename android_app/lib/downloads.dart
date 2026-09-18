import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'storage.dart';
import 'models.dart';

/// Downloads films and episodes to the phone for watching offline.
///
/// One download runs at a time, over one connection, as fast as that
/// connection goes — the provider allows a single connection per account, so
/// splitting a file into parallel ranges only gets connections refused.
/// Downloads keep going while something is watched (the provider now and then
/// drops the download's connection; it reconnects and carries on from the
/// same byte). That can be switched off, in which case a download waits
/// until playback ends.
///
/// Data goes to "<name>.part" and is renamed when complete, so a dropped
/// connection or a closed app picks up where it stopped.
class DownloadManager extends ChangeNotifier {
  static const _userAgent = 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100';
  static const _retryStatus = {401, 403, 408, 429, 458, 500, 502, 503, 504, 509};

  final List<DownloadItem> items = [];
  String dir = '';
  String defaultDir = '';
  bool whileWatching = true;

  bool _playbackActive = false;
  _Active? _active;
  Timer? _ticker;
  Timer? _saveTimer;
  Timer? _retryTimer;
  Timer? _initTimer;
  int _lastNotify = 0;

  @override
  void dispose() {
    _initTimer?.cancel();
    _ticker?.cancel();
    _saveTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> init() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    defaultDir = '${base.path}/Downloads';
    dir = Storage.p.getString('downloadDir') ?? defaultDir;
    whileWatching = Storage.p.getBool('downloadWhileWatching') ?? true;
    final raw = Storage.p.getString('downloads');
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          final it = DownloadItem.fromJson(Map<String, dynamic>.from(e));
          if (it.status == 'downloading' || it.status == 'waiting') it.status = 'queued';
          items.add(it);
        }
      } catch (_) {}
    }
    _initTimer = Timer(const Duration(seconds: 3), _pump);
  }

  // ---- queries ----

  DownloadItem? byUrl(String url) {
    for (final it in items) {
      if (it.url == url) return it;
    }
    return null;
  }

  DownloadItem? byId(String id) {
    for (final it in items) {
      if (it.id == id) return it;
    }
    return null;
  }

  int get completedCount => items.where((i) => i.status == 'completed').length;

  // ---- settings ----

  /// Returns an error message, or null when the folder is usable.
  Future<String?> setDir(String path) async {
    try {
      final d = Directory(path);
      await d.create(recursive: true);
      final probe = File('${d.path}/.write-test-${DateTime.now().millisecondsSinceEpoch}');
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (e) {
      return "This folder can't be written to on this phone. Pick another, or keep the default.";
    }
    dir = path;
    await Storage.p.setString('downloadDir', path);
    // Downloads that haven't written anything yet go to the new place too.
    for (final it in items) {
      if (it.status != 'completed' && it.receivedBytes == 0 && _active?.item != it) {
        it.filePath = await _uniquePath(_targetPath(it.title, it.subtitle, it.type, _ext(it.filePath)));
      }
    }
    _save();
    notifyListeners();
    return null;
  }

  Future<void> setWhileWatching(bool on) async {
    whileWatching = on;
    await Storage.p.setBool('downloadWhileWatching', on);
    if (on) {
      _pump();
    } else if (_playbackActive && _active != null) {
      _stopActive('waiting');
    }
    notifyListeners();
  }

  void playbackStarted() {
    _playbackActive = true;
    if (!whileWatching && _active != null) _stopActive('waiting');
  }

  void playbackEnded() {
    _playbackActive = false;
    Timer(const Duration(seconds: 2), _pump);
  }

  // ---- actions ----

  bool _storagePermissionAsked = false;

  // Downloads already land in this app's own scoped-storage folder, which
  // needs no permission at all on modern Android — but the user explicitly
  // wants the same "app asks before touching your files" prompt a
  // professional app shows. This used to run lazily on the first download
  // request, which could land while a movie was playing full-screen
  // (download-while-watching is a real, supported flow) — the system
  // permission dialog popping up over the immersive video surface is what
  // was leaving a stuck white frame with audio still playing. Called once
  // instead at app boot (main.dart), before any player screen exists.
  // `Permission.storage.request()` resolves to already-granted on its own on
  // Android 13+ where it no longer applies, so this is a no-op dialog-wise
  // there.
  Future<void> ensureStoragePermission() async {
    if (_storagePermissionAsked) return;
    _storagePermissionAsked = true;
    try {
      await Permission.storage.request();
    } catch (_) {}
  }

  Future<DownloadItem> add({
    required String url,
    required String title,
    String subtitle = '',
    String type = 'movie',
    String thumb = '',
  }) async {
    final existing = byUrl(url);
    if (existing != null) {
      if (existing.status == 'failed') {
        existing.status = 'queued';
        existing.error = '';
        _changed(save: true);
        _pump();
      }
      return existing;
    }
    final ext = _ext(url.split('?').first);
    final item = DownloadItem(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      url: url,
      title: title,
      subtitle: subtitle,
      type: type,
      thumb: thumb,
      filePath: await _uniquePath(_targetPath(title, subtitle, type, ext)),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    items.insert(0, item);
    _changed(save: true);
    _pump();
    return item;
  }

  void pause(String id) {
    final it = byId(id);
    if (it == null || it.status == 'completed') return;
    if (_active?.item == it) {
      _stopActive('paused');
    } else {
      it.status = 'paused';
    }
    _changed(save: true);
    _pump();
  }

  void resume(String id) {
    final it = byId(id);
    if (it == null || it.status == 'completed' || it.status == 'downloading') return;
    it.status = 'queued';
    it.error = '';
    _changed(save: true);
    _pump();
  }

  Future<void> remove(String id, {bool deleteFile = true}) async {
    final it = byId(id);
    if (it == null) return;
    if (_active?.item == it) _stopActive(null);
    items.remove(it);
    try { await File('${it.filePath}.part').delete(); } catch (_) {}
    if (deleteFile || it.status != 'completed') {
      try { await File(it.filePath).delete(); } catch (_) {}
    }
    _changed(save: true);
    _pump();
  }

  // ---- engine ----

  void _pump() {
    if (_active != null) return;
    if (!whileWatching && _playbackActive) return;
    DownloadItem? next;
    for (final it in items) {
      if (it.status == 'waiting') { next = it; break; }
    }
    if (next == null) {
      for (final it in items.reversed) {
        if (it.status == 'queued') { next = it; break; }
      }
    }
    if (next != null) _start(next);
  }

  void _start(DownloadItem item) {
    final a = _Active(item);
    _active = a;
    item.status = 'downloading';
    item.error = '';
    _ensureTicker();
    _changed(save: true);
    _request(a);
  }

  Future<void> _request(_Active a) async {
    if (_active != a) return;
    final item = a.item;
    final part = File('${item.filePath}.part');
    int have = 0;
    try {
      if (await part.exists()) have = await part.length();
    } catch (_) {}
    item.receivedBytes = have;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30);
    a.client = client;
    try {
      await part.parent.create(recursive: true);
      final req = await client.getUrl(Uri.parse(item.url));
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      req.followRedirects = true;
      req.maxRedirects = 8;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (_active != a) { client.close(force: true); return; }

      if (res.statusCode == 416 && have > 0 && item.totalBytes > 0 && have >= item.totalBytes) {
        await res.drain<void>().catchError((_) {});
        await _finish(a);
        return;
      }
      if (res.statusCode != 200 && res.statusCode != 206) {
        await res.drain<void>().catchError((_) {});
        if (_retryStatus.contains(res.statusCode)) {
          _retry(a, 'HTTP ${res.statusCode}');
        } else {
          _fail(a, 'Server answered HTTP ${res.statusCode}');
        }
        return;
      }
      final appending = res.statusCode == 206 && have > 0;
      if (res.statusCode == 206) {
        final rangeHeader = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final m = RegExp(r'/(\d+)\s*$').firstMatch(rangeHeader);
        if (m != null) {
          item.totalBytes = int.parse(m.group(1)!);
        } else if (item.totalBytes <= 0) {
          // Content-Range present but unparseable (e.g. "bytes */total") and
          // we don't know the total yet — treat as unknown-length download
          // that finishes when the server closes the connection.
          item.totalBytes = 0;
        }
      } else if (res.contentLength > 0) {
        item.totalBytes = res.contentLength;
      }
      if (!appending) item.receivedBytes = 0; // a server that ignores Range starts over

      final sink = part.openWrite(mode: appending ? FileMode.append : FileMode.write);
      a.retries = 0;
      try {
        await sink.addStream(res.map((chunk) {
          item.receivedBytes += chunk.length;
          a.windowBytes += chunk.length;
          return chunk;
        }));
      } finally {
        await sink.flush().catchError((_) {});
        await sink.close().catchError((_) {});
      }
      if (_active != a) return;
      if (item.totalBytes > 0 && item.receivedBytes < item.totalBytes) {
        _retry(a, 'connection ended early');
      } else {
        await _finish(a);
      }
    } catch (e) {
      if (_active != a) return;
      if (e is FileSystemException) {
        _fail(a, "Couldn't write the file (${e.osError?.message ?? e.message}). Is the storage full?");
      } else {
        _retry(a, 'connection dropped');
      }
    } finally {
      client.close(force: true);
    }
  }

  void _retry(_Active a, String why) {
    if (_active != a) return;
    a.retries++;
    if (a.retries > 10) {
      _fail(a, why);
      return;
    }
    final shift = (a.retries - 1).clamp(0, 4).toInt();
    final delay = Duration(milliseconds: (1000 * (1 << shift)).clamp(1000, 15000).toInt());
    debugPrint('[downloads] ${a.item.title}: $why — retry ${a.retries} in ${delay.inMilliseconds}ms');
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => _request(a));
  }

  void _fail(_Active a, String message) {
    if (_active != a) return;
    _stopActive('failed');
    a.item.error = message;
    _changed(save: true);
    _pump();
  }

  Future<void> _finish(_Active a) async {
    if (_active != a) return;
    final item = a.item;
    _stopActive(null);
    try {
      var target = item.filePath;
      if (await File(target).exists()) target = await _uniquePath(target);
      await File('${item.filePath}.part').rename(target);
      item.filePath = target;
      item.status = 'completed';
      item.completedAt = DateTime.now().millisecondsSinceEpoch;
      if (item.totalBytes == 0) item.totalBytes = item.receivedBytes;
    } catch (e) {
      item.status = 'failed';
      item.error = "Couldn't finish the file.";
    }
    _changed(save: true);
    _pump();
  }

  void _stopActive(String? nextStatus) {
    final a = _active;
    if (a == null) return;
    _active = null;
    _retryTimer?.cancel();
    try { a.client?.close(force: true); } catch (_) {}
    a.item.speed = 0;
    if (nextStatus != null) a.item.status = nextStatus;
    _changed(save: true);
  }

  // Once a second: speed, time left, and a redraw for whatever shows them.
  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final a = _active;
      if (a == null) {
        _ticker?.cancel();
        _ticker = null;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final secs = ((now - a.windowStart) / 1000).clamp(0.25, 10.0);
      final instant = a.windowBytes / secs;
      a.item.speed = a.item.speed == 0 ? instant : a.item.speed * 0.6 + instant * 0.4;
      a.windowBytes = 0;
      a.windowStart = now;
      _changed();
    });
  }

  void _changed({bool save = false}) {
    if (save) {
      _save();
    } else {
      _saveTimer ??= Timer(const Duration(seconds: 5), _save);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (save || now - _lastNotify > 100) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    Storage.p.setString('downloads', jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  // ---- file names ----

  static String _ext(String path) {
    final m = RegExp(r'\.([A-Za-z0-9]{2,4})$').firstMatch(path);
    return (m?.group(1) ?? 'mp4').toLowerCase();
  }

  static String _safe(String s) {
    final cleaned = s
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty) return 'video';
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  String _targetPath(String title, String subtitle, String type, String ext) {
    if (type == 'episode') {
      final series = _safe(title);
      final m = RegExp(r'Season\s+(\S+)\s*-\s*Episode\s+(\S+)\s*(?:-\s*(.*))?$', caseSensitive: false).firstMatch(subtitle);
      final tag = m != null ? 'S${m.group(1)!.padLeft(2, '0')}E${m.group(2)!.padLeft(2, '0')}' : '';
      final ep = m?.group(3)?.trim().isNotEmpty == true ? ' - ${m!.group(3)}' : '';
      return '$dir/$series/${_safe('$series${tag.isNotEmpty ? ' - $tag' : ''}$ep')}.$ext';
    }
    return '$dir/${_safe(title)}.$ext';
  }

  static Future<String> _uniquePath(String p) async {
    if (!await File(p).exists() && !await File('$p.part').exists()) return p;
    final dot = p.lastIndexOf('.');
    final base = dot > 0 ? p.substring(0, dot) : p;
    final ext = dot > 0 ? p.substring(dot) : '';
    for (var n = 2; n < 1000; n++) {
      final c = '$base ($n)$ext';
      if (!await File(c).exists() && !await File('$c.part').exists()) return c;
    }
    return '$base ${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}

class _Active {
  final DownloadItem item;
  HttpClient? client;
  int retries = 0;
  int windowBytes = 0;
  int windowStart = DateTime.now().millisecondsSinceEpoch;
  _Active(this.item);
}

String fmtBytes(num n) {
  if (n <= 0) return '0 MB';
  if (n >= 1073741824) return '${(n / 1073741824).toStringAsFixed(2)} GB';
  if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(n >= 104857600 ? 0 : 1)} MB';
  return '${(n / 1024).round().clamp(1, 1023)} KB';
}

String fmtSpeed(double bps) {
  if (bps <= 0) return '—';
  return bps >= 1048576 ? '${(bps / 1048576).toStringAsFixed(1)} MB/s' : '${(bps / 1024).round()} KB/s';
}

String fmtEta(double? sec) {
  if (sec == null || !sec.isFinite) return '';
  final s = sec.round();
  if (s < 60) return '$s sec left';
  final m = s ~/ 60;
  if (m < 60) return '$m min ${(s % 60).toString().padLeft(2, '0')} sec left';
  return '${m ~/ 60} hr ${(m % 60).toString().padLeft(2, '0')} min left';
}

String downloadStatusText(DownloadItem d) {
  final pct = '${(d.progress * 100).floor()}%';
  final sizes = d.totalBytes > 0 ? '${fmtBytes(d.receivedBytes)} of ${fmtBytes(d.totalBytes)}' : fmtBytes(d.receivedBytes);
  switch (d.status) {
    case 'downloading':
      final eta = fmtEta(d.eta);
      return 'Downloading · $pct · $sizes · ${fmtSpeed(d.speed)}${eta.isNotEmpty ? ' · $eta' : ''}';
    case 'waiting':
      return 'Paused while you watch · $pct · $sizes';
    case 'queued':
      return d.receivedBytes > 0 ? 'Waiting to continue · $pct · $sizes' : 'Waiting — starts after the current download';
    case 'paused':
      return 'Paused · $pct · $sizes';
    case 'failed':
      return 'Failed — ${d.error.isEmpty ? 'unknown error' : d.error}';
    case 'completed':
      return 'Downloaded · ${fmtBytes(d.totalBytes > 0 ? d.totalBytes : d.receivedBytes)}';
    default:
      return d.status;
  }
}
