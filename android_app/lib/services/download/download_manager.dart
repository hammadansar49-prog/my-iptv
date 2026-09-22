import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/constants/app_constants.dart' as consts;
import '../../core/network/connection_guard.dart';
import '../../core/storage/local_store.dart';
import '../../core/utils/logger.dart';
import '../../data/models/library.dart';

/// Metadata for a new download request.
class DownloadRequest {
  const DownloadRequest({
    required this.url,
    required this.title,
    required this.ext,
    this.subtitle = '',
    this.seriesName = '',
    this.thumb,
    this.isEpisode = false,
    this.seasonEpisodeTag = '',
  });

  final String url;
  final String title;
  final String ext;
  final String subtitle;
  final String seriesName;
  final String? thumb;
  final bool isEpisode;
  final String seasonEpisodeTag;
}

/// Port of `downloads.js`.
///
/// The rules that matter, all from AUDIT.md §5:
///  * ONE download at a time. Parallel ranges get refused by a
///    one-connection panel; they do not go faster.
///  * Bytes go to `<file>.part` and the download resumes with
///    `Range: bytes=<have>-`. A server that ignores Range (answers 200)
///    restarts the file rather than corrupting it.
///  * A fixed retryable-status set, exponential backoff capped at 15s, and
///    at most 10 retries before the item fails.
///  * The progress ticker stops itself when nothing is active — spec §47
///    is explicit about not leaving timers running.
class DownloadManager {
  DownloadManager({
    required LocalStore store,
    required ConnectionGuard guard,
    Dio? dio,
  })  : _store = store,
        _guard = guard,
        _dio = dio ?? Dio() {
    _items = _store
        .readList(_kItems)
        .map(DownloadItem.fromJson)
        .toList();
  }

  static const _tag = 'DownloadManager';
  static const _kItems = 'downloads';
  static const _kDir = 'downloads_dir';

  final LocalStore _store;
  final ConnectionGuard _guard;
  final Dio _dio;

  late List<DownloadItem> _items;
  String? _rootDir;

  final _changes = StreamController<List<DownloadItem>>.broadcast();
  Stream<List<DownloadItem>> get changes => _changes.stream;

  List<DownloadItem> get items => List.unmodifiable(_items);

  // Active transfer state.
  String? _activeId;
  CancelToken? _cancelToken;
  IOSink? _sink;
  ProviderLease? _lease;
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _ticker;
  bool _disposed = false;

  /// Smoothed bytes/sec per item id.
  final Map<String, double> _speeds = {};
  int _windowBytes = 0;
  DateTime _windowStart = DateTime.now();

  double speedOf(String id) => _speeds[id] ?? 0;

  Duration? etaOf(DownloadItem item) {
    final speed = _speeds[item.id] ?? 0;
    if (speed <= 0 || item.totalBytes <= 0) return null;
    return Duration(seconds: (item.remainingBytes / speed).round());
  }

  Future<void> init() async {
    final saved = _store.read<String>(_kDir);
    if (saved != null && saved.isNotEmpty) {
      _rootDir = saved;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      _rootDir = '${dir.path}${Platform.pathSeparator}Downloads';
    }
    await Directory(_rootDir!).create(recursive: true);
    // Anything left mid-flight by a kill is already normalised to `queued`
    // by DownloadItem.toJson; start whatever is waiting.
    unawaited(Future.delayed(const Duration(seconds: 3), _pump));
  }

  String get rootDir => _rootDir ?? '';

  // ---- Queue operations ---------------------------------------------------

  Future<DownloadItem> add(DownloadRequest request) async {
    final existing = _items.firstWhereOrNull(
      (it) => it.url == request.url && it.status != DownloadStatus.failed,
    );
    if (existing != null) return existing;

    // A previously failed item for the same URL is requeued, not duplicated.
    final failedIdx =
        _items.indexWhere((it) => it.url == request.url);
    if (failedIdx >= 0) {
      _items[failedIdx] =
          _items[failedIdx].copyWith(status: DownloadStatus.queued, error: '');
      _persist();
      unawaited(_pump());
      return _items[failedIdx];
    }

    final item = DownloadItem(
      id: _newId(),
      url: request.url,
      title: request.title,
      subtitle: request.subtitle,
      seriesName: request.seriesName,
      thumb: request.thumb,
      isEpisode: request.isEpisode,
      filePath: await _uniquePath(_targetPath(request)),
      status: DownloadStatus.queued,
      addedAt: DateTime.now(),
    );
    _items.insert(0, item);
    _persist();
    unawaited(_pump());
    return item;
  }

  Future<void> pause(String id) async {
    final item = _find(id);
    if (item == null || item.status == DownloadStatus.completed) return;
    if (_activeId == id) {
      await _stopActive(DownloadStatus.paused);
    } else {
      _update(id, (it) => it.copyWith(status: DownloadStatus.paused));
    }
    unawaited(_pump());
  }

  Future<void> resume(String id) async {
    final item = _find(id);
    if (item == null ||
        item.status == DownloadStatus.completed ||
        item.status == DownloadStatus.downloading) {
      return;
    }
    _update(id, (it) => it.copyWith(status: DownloadStatus.queued, error: ''));
    unawaited(_pump());
  }

  Future<void> remove(String id, {bool deleteFile = true}) async {
    final item = _find(id);
    if (item == null) return;
    if (_activeId == id) await _stopActive(null);

    await _deleteQuietly(item.partPath);
    if (deleteFile || item.status != DownloadStatus.completed) {
      await _deleteQuietly(item.filePath);
    }
    _items.removeWhere((it) => it.id == id);
    _speeds.remove(id);
    _persist();
    unawaited(_pump());
  }

  /// The completed local file for a URL, if it exists — so a downloaded item
  /// plays from disk instead of re-streaming (spec §29).
  String? localFileFor(String url) {
    final item = _items.firstWhereOrNull(
      (it) => it.url == url && it.status == DownloadStatus.completed,
    );
    if (item == null) return null;
    return File(item.filePath).existsSync() ? item.filePath : null;
  }

  // ---- Transfer -----------------------------------------------------------

  Future<void> _pump() async {
    if (_disposed || _activeId != null) return;

    // Playback owns the provider connection unless the account has room.
    if (_guard.hasPlayback && !_guard.allowConcurrentDownloads) return;

    final next = _items.firstWhereOrNull((it) => it.status == DownloadStatus.waiting) ??
        _items.lastWhereOrNull((it) => it.status == DownloadStatus.queued);
    if (next == null) return;

    final lease = _guard.tryAcquire(ProviderUse.download, label: next.title);
    if (lease == null) {
      // Busy; try again shortly rather than spinning.
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 4), () => unawaited(_pump()));
      return;
    }
    // Playback pre-empting us parks the item as `waiting`, which _pump picks
    // up first once the connection frees.
    lease.onPreempted = () {
      Log.i(_tag, 'yielding "${next.title}" to playback');
      unawaited(_stopActive(DownloadStatus.waiting));
      _retryTimer?.cancel();
      _retryTimer = Timer(
        consts.Downloads.resumeAfterPlayback,
        () => unawaited(_pump()),
      );
    };

    _lease = lease;
    _activeId = next.id;
    _retries = 0;
    await _start(next);
  }

  Future<void> _start(DownloadItem item) async {
    // Resume from whatever is already on disk.
    var have = 0;
    try {
      final part = File(item.partPath);
      if (await part.exists()) have = await part.length();
    } catch (_) {}

    _update(item.id, (it) => it.copyWith(
          status: DownloadStatus.downloading,
          receivedBytes: have,
          error: '',
        ));
    _ensureTicker();
    await _request(item.id, item.url, have, 0);
  }

  Future<void> _request(String id, String url, int from, int depth) async {
    if (_disposed || _activeId != id) return;
    if (depth > consts.Downloads.maxRedirects) {
      await _fail(id, 'Too many redirects');
      return;
    }

    final cancel = CancelToken();
    _cancelToken = cancel;

    try {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: consts.Downloads.socketTimeout,
          headers: {
            'User-Agent': consts.Api.downloadUserAgent,
            'Accept-Encoding': 'identity',
            if (from > 0) 'Range': 'bytes=$from-',
          },
        ),
      );
      if (_disposed || _activeId != id) return;

      final status = response.statusCode ?? 0;

      if (status >= 300 && status < 400) {
        final location = response.headers.value('location');
        if (location == null) {
          await _fail(id, 'Bad redirect');
          return;
        }
        final next = Uri.parse(url).resolve(location).toString();
        await _request(id, next, from, depth + 1);
        return;
      }

      final item = _find(id);
      if (item == null) return;

      // Already have the whole file.
      if (status == 416 && from > 0 && item.totalBytes > 0 && from >= item.totalBytes) {
        await _finish(id);
        return;
      }

      if (status != 200 && status != 206) {
        if (consts.Downloads.retryableStatus.contains(status)) {
          await _retry(id, url, 'HTTP $status');
        } else {
          await _fail(id, 'Server answered HTTP $status');
        }
        return;
      }

      // A 206 means our Range was honoured and we append. A 200 means the
      // server ignored it, so the file starts over.
      final appending = status == 206 && from > 0;
      var total = item.totalBytes;
      if (status == 206) {
        final range = response.headers.value('content-range') ?? '';
        final match = RegExp(r'/(\d+)\s*$').firstMatch(range);
        if (match != null) total = int.tryParse(match.group(1)!) ?? total;
      } else {
        final len = int.tryParse(response.headers.value('content-length') ?? '');
        if (len != null && len > 0) total = len;
      }

      final received = appending ? from : 0;
      _update(id, (it) => it.copyWith(totalBytes: total, receivedBytes: received));

      final file = File(item.partPath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite(
        mode: appending ? FileMode.append : FileMode.write,
      );
      _sink = sink;
      _retries = 0;

      var written = received;
      try {
        await for (final chunk in response.data!.stream) {
          if (_disposed || _activeId != id) break;
          sink.add(chunk);
          written += chunk.length;
          _windowBytes += chunk.length;
          _updateQuiet(id, (it) => it.copyWith(receivedBytes: written));
        }
        await sink.flush();
      } finally {
        await sink.close();
        if (_sink == sink) _sink = null;
      }

      if (_disposed || _activeId != id) return;

      final current = _find(id);
      if (current == null) return;
      if (current.totalBytes > 0 && written < current.totalBytes) {
        await _retry(id, url, 'connection ended at $written/${current.totalBytes}');
        return;
      }
      await _finish(id);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (_disposed || _activeId != id) return;
      await _retry(id, url, e.message ?? 'connection dropped');
    } catch (e) {
      if (_disposed || _activeId != id) return;
      await _fail(id, 'Could not write the file: $e');
    }
  }

  Future<void> _retry(String id, String url, String why) async {
    if (_activeId != id) return;
    _retries++;
    if (_retries > consts.Downloads.maxRetries) {
      await _fail(id, why);
      return;
    }
    final ms = min(
      consts.Downloads.maxBackoff.inMilliseconds,
      1000 * (1 << min(4, _retries - 1)),
    );
    Log.i(_tag, 'retry $_retries for $id: $why in ${ms}ms');
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: ms), () async {
      if (_activeId != id || _disposed) return;
      var have = 0;
      final item = _find(id);
      if (item != null) {
        try {
          final part = File(item.partPath);
          if (await part.exists()) have = await part.length();
        } catch (_) {}
      }
      await _request(id, url, have, 0);
    });
  }

  Future<void> _fail(String id, String message) async {
    Log.w(_tag, 'download $id failed: $message');
    await _stopActive(null);
    _update(id, (it) => it.copyWith(status: DownloadStatus.failed, error: message));
    unawaited(_pump());
  }

  Future<void> _finish(String id) async {
    final item = _find(id);
    if (item == null) return;
    await _stopActive(null);
    try {
      final part = File(item.partPath);
      final finalPath = await _uniquePath(item.filePath);
      await part.rename(finalPath);
      _update(
        id,
        (it) => it.copyWith(
          status: DownloadStatus.completed,
          filePath: finalPath,
          completedAt: DateTime.now(),
          totalBytes: it.totalBytes > 0 ? it.totalBytes : it.receivedBytes,
        ),
      );
      Log.i(_tag, 'completed "${item.title}"');
    } catch (e) {
      _update(id, (it) => it.copyWith(
            status: DownloadStatus.failed,
            error: 'Could not finish the file: $e',
          ));
    }
    unawaited(_pump());
  }

  Future<void> _stopActive(DownloadStatus? nextStatus) async {
    final id = _activeId;
    _activeId = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    try {
      _cancelToken?.cancel('stopped');
    } catch (_) {}
    _cancelToken = null;

    try {
      await _sink?.close();
    } catch (_) {}
    _sink = null;

    _lease?.release();
    _lease = null;

    if (id != null) {
      _speeds.remove(id);
      if (nextStatus != null) {
        _update(id, (it) => it.copyWith(status: nextStatus));
      }
    }
    _stopTickerIfIdle();
  }

  // ---- Speed ticker -------------------------------------------------------

  void _ensureTicker() {
    if (_ticker != null) return;
    _windowBytes = 0;
    _windowStart = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final id = _activeId;
      if (id == null) {
        _stopTickerIfIdle();
        return;
      }
      final now = DateTime.now();
      final secs = max(0.25, now.difference(_windowStart).inMilliseconds / 1000);
      final instant = _windowBytes / secs;
      final prev = _speeds[id];
      // Same EMA the PC app uses.
      _speeds[id] = prev == null ? instant : prev * 0.6 + instant * 0.4;
      _windowBytes = 0;
      _windowStart = now;
      _emit();
    });
  }

  void _stopTickerIfIdle() {
    if (_activeId != null) return;
    _ticker?.cancel();
    _ticker = null;
  }

  // ---- Paths --------------------------------------------------------------

  String _targetPath(DownloadRequest r) {
    final sep = Platform.pathSeparator;
    final ext = _safeName(r.ext).replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (r.isEpisode) {
      final series = _safeName(r.seriesName.isEmpty ? r.title : r.seriesName);
      final tag = r.seasonEpisodeTag.isEmpty ? '' : ' - ${r.seasonEpisodeTag}';
      final epTitle = r.subtitle.isEmpty ? '' : ' - ${r.subtitle}';
      return '$rootDir$sep$series$sep${_safeName('$series$tag$epTitle')}.${ext.isEmpty ? 'mp4' : ext}';
    }
    return '$rootDir$sep${_safeName(r.title)}.${ext.isEmpty ? 'mp4' : ext}';
  }

  static String _safeName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    final capped = cleaned.length > 140 ? cleaned.substring(0, 140) : cleaned;
    return capped.isEmpty ? 'video' : capped;
  }

  Future<String> _uniquePath(String path) async {
    if (!await File(path).exists() && !await File('$path.part').exists()) {
      return path;
    }
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 ? path.substring(dot) : '';
    final base = dot > 0 ? path.substring(0, dot) : path;
    for (var n = 2; n < 1000; n++) {
      final candidate = '$base ($n)$ext';
      if (!await File(candidate).exists() &&
          !await File('$candidate.part').exists()) {
        return candidate;
      }
    }
    return '$base ${DateTime.now().millisecondsSinceEpoch}$ext';
  }

  static String _newId() {
    final r = Random();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ---- State plumbing -----------------------------------------------------

  DownloadItem? _find(String id) => _items.firstWhereOrNull((it) => it.id == id);

  void _update(String id, DownloadItem Function(DownloadItem) change) {
    final idx = _items.indexWhere((it) => it.id == id);
    if (idx < 0) return;
    _items[idx] = change(_items[idx]);
    _persist();
  }

  /// Progress-only update: no disk write (it fires per chunk), just a UI
  /// notification on the next ticker beat.
  void _updateQuiet(String id, DownloadItem Function(DownloadItem) change) {
    final idx = _items.indexWhere((it) => it.id == id);
    if (idx < 0) return;
    _items[idx] = change(_items[idx]);
  }

  void _persist() {
    _store.write(_kItems, _items.map((it) => it.toJson()).toList());
    _emit();
  }

  void _emit() {
    if (_disposed || _changes.isClosed) return;
    _changes.add(items);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _stopActive(DownloadStatus.queued);
    _ticker?.cancel();
    _retryTimer?.cancel();
    _store.write(_kItems, _items.map((it) => it.toJson()).toList());
    await _store.flush();
    await _changes.close();
  }
}

extension _FirstWhereOrNull<E> on List<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }

  E? lastWhereOrNull(bool Function(E) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
