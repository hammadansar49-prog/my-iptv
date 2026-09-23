import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/constants/app_constants.dart' as consts;
import '../../core/network/connection_guard.dart';
import '../../core/storage/local_store.dart';
import '../../core/utils/logger.dart';
import '../../data/models/library.dart';
import 'download_service_bridge.dart';

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

/// Thrown inside the transfer loop when the stall watchdog fires.
class _StallException implements Exception {
  const _StallException();
  @override
  String toString() => 'no data for 30 seconds';
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
///    at most 10 retries before the item fails. The counter resets whenever
///    an attempt actually moved bytes, so a long download over a flaky link
///    never fails just because it dropped 11 times in an hour.
///  * The progress ticker stops itself when nothing is active — spec §47
///    is explicit about not leaving timers running.
///
/// Throughput: the hot loop does nothing per chunk except copy into a 1 MiB
/// buffer; disk writes are 1 MiB `RandomAccessFile.writeFrom` calls, and
/// progress/UI/notification updates happen on the 1 s ticker only.
class DownloadManager {
  DownloadManager({
    required LocalStore store,
    required ConnectionGuard guard,
    Dio? dio,
    DownloadServiceBridge? service,
  })  : _store = store,
        _guard = guard,
        _dio = dio ?? _makeDio(),
        _service = service ?? DownloadServiceBridge() {
    _items = _store
        .readList(_kItems)
        .map(DownloadItem.fromJson)
        .toList();
    _service.onAction = _onNotificationAction;
  }

  static Dio _makeDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: consts.Downloads.socketTimeout,
    ));
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..autoUncompress = false
        ..idleTimeout = const Duration(seconds: 5)
        ..connectionTimeout = const Duration(seconds: 20),
    );
    return dio;
  }

  static const _tag = 'DownloadManager';
  static const _kItems = 'downloads';
  static const _kDir = 'downloads_dir';
  static const _bufferSize = 1 << 20; // 1 MiB disk writes
  static const _stallAfter = Duration(seconds: 30);

  final LocalStore _store;
  final ConnectionGuard _guard;
  final Dio _dio;
  final DownloadServiceBridge _service;

  late List<DownloadItem> _items;
  String? _rootDir;
  bool _inited = false;

  final _changes = StreamController<List<DownloadItem>>.broadcast();
  Stream<List<DownloadItem>> get changes => _changes.stream;

  List<DownloadItem> get items => List.unmodifiable(_items);

  // Active transfer state.
  String? _activeId;
  CancelToken? _cancelToken;
  ProviderLease? _lease;
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _ticker;
  bool _disposed = false;

  /// Live byte count of the running transfer; folded into the item on the
  /// ticker, never per chunk.
  int _liveBytes = -1;
  DateTime _lastByteAt = DateTime.now();
  bool _stalled = false;

  /// The item the notification is about; kept while it is paused so the
  /// notification can offer "Resume".
  String? _notifId;

  // Connectivity.
  StreamSubscription<List<ConnectivityResult>>? _netSub;
  bool _online = true;
  /// Items that failed on a network error — requeued when the network returns.
  final Set<String> _netFailed = {};

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
    if (_inited) return;
    _inited = true;
    final saved = _store.read<String>(_kDir);
    if (saved != null && saved.isNotEmpty) {
      _rootDir = saved;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      _rootDir = '${dir.path}${Platform.pathSeparator}Downloads';
    }
    await Directory(_rootDir!).create(recursive: true);
    try {
      _netSub = Connectivity().onConnectivityChanged.listen(_onConnectivity);
    } catch (e) {
      Log.w(_tag, 'connectivity unavailable: $e');
    }
    // Anything left mid-flight by a kill is already normalised to `queued`
    // by DownloadItem.toJson; start whatever is waiting.
    unawaited(Future.delayed(const Duration(seconds: 3), _pump));
  }

  String get rootDir => _rootDir ?? '';

  void _onConnectivity(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    final cameBack = online && !_online;
    _online = online;
    if (!cameBack || _disposed) return;
    Log.i(_tag, 'network back — resuming downloads');
    for (final id in _netFailed.toList()) {
      final it = _find(id);
      if (it != null && it.status == DownloadStatus.failed) {
        _update(id, (x) => x.copyWith(status: DownloadStatus.queued, error: ''));
      }
    }
    _netFailed.clear();
    // An active item sitting in backoff retries right now.
    final id = _activeId;
    if (id != null && _retryTimer != null && _cancelToken == null) {
      _retryTimer?.cancel();
      _retryTimer = null;
      unawaited(_attempt(id));
    }
    unawaited(_pump());
  }

  // ---- Notification actions ------------------------------------------------

  void _onNotificationAction(String action, String id) {
    switch (action) {
      case 'pause':
        unawaited(pause(id));
      case 'resume':
        unawaited(resume(id));
      case 'cancel':
        unawaited(remove(id));
    }
  }

  // ---- Queue operations ---------------------------------------------------

  Future<DownloadItem> add(DownloadRequest request) async {
    unawaited(_service.ensureNotificationPermission());
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
    _netFailed.remove(id);
    if (_activeId == id) {
      await _stopActive(DownloadStatus.paused);
    } else {
      _update(id, (it) => it.copyWith(status: DownloadStatus.paused));
    }
    unawaited(_pump());
  }

  /// Pause every unfinished download. Used when the subscription ends
  /// mid-session (the licence watcher), so nothing keeps pulling from the
  /// provider behind the "Subscription ended" screen.
  Future<void> pauseAll() async {
    final ids = _items
        .where((it) =>
            it.status == DownloadStatus.downloading ||
            it.status == DownloadStatus.queued ||
            it.status == DownloadStatus.waiting)
        .map((it) => it.id)
        .toList();
    for (final id in ids) {
      await pause(id);
    }
  }

  Future<void> resume(String id) async {
    final item = _find(id);
    if (item == null ||
        item.status == DownloadStatus.completed ||
        item.status == DownloadStatus.downloading) {
      return;
    }
    unawaited(_service.ensureNotificationPermission());
    _netFailed.remove(id);
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
    _netFailed.remove(id);
    if (_notifId == id) _notifId = null;
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
    if (next == null) {
      _syncService();
      return;
    }

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
    _notifId = next.id;
    _retries = 0;
    _update(next.id, (it) => it.copyWith(
          status: DownloadStatus.downloading,
          error: '',
        ));
    _ensureTicker();
    await _attempt(next.id);
  }

  /// One attempt: resume from whatever `.part` holds right now.
  Future<void> _attempt(String id) async {
    if (_disposed || _activeId != id) return;
    final item = _find(id);
    if (item == null) return;
    var have = 0;
    try {
      final part = File(item.partPath);
      if (await part.exists()) have = await part.length();
    } catch (_) {}
    // A .part already holding the full size: finish instead of asking for
    // an empty range.
    if (item.totalBytes > 0 && have >= item.totalBytes) {
      await _finish(id);
      return;
    }
    _updateQuiet(id, (it) => it.copyWith(receivedBytes: have));
    await _request(id, item.url, have, 0);
  }

  Future<void> _request(String id, String url, int from, int depth) async {
    if (_disposed || _activeId != id) return;
    if (depth > consts.Downloads.maxRedirects) {
      await _fail(id, 'Too many redirects');
      return;
    }

    final cancel = CancelToken();
    _cancelToken = cancel;
    _stalled = false;
    _lastByteAt = DateTime.now();
    var written = from;
    RandomAccessFile? raf;

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
            'Connection': 'keep-alive',
            if (from > 0) 'Range': 'bytes=$from-',
          },
        ),
      );
      if (_disposed || _activeId != id) {
        cancel.cancel('stale');
        return;
      }

      final status = response.statusCode ?? 0;

      if (status >= 300 && status < 400) {
        cancel.cancel('redirect');
        final location = response.headers.value('location');
        if (location == null) {
          await _fail(id, 'Bad redirect');
          return;
        }
        final next = Uri.parse(url).resolve(location).toString();
        _cancelToken = null;
        await _request(id, next, from, depth + 1);
        return;
      }

      final item = _find(id);
      if (item == null) return;

      // Already have the whole file.
      if (status == 416 && from > 0 && (item.totalBytes <= 0 || from >= item.totalBytes)) {
        cancel.cancel('done');
        await _finish(id);
        return;
      }

      if (status != 200 && status != 206) {
        cancel.cancel('bad status');
        _cancelToken = null;
        if (consts.Downloads.retryableStatus.contains(status)) {
          await _retry(id, 'HTTP $status', progressed: false);
        } else {
          await _fail(id, 'Server answered HTTP $status');
        }
        return;
      }

      // A 206 means our Range was honoured and we append. A 200 means the
      // server ignored it, so the file starts over (truncate).
      var start = 0;
      var total = item.totalBytes;
      if (status == 206) {
        final range = response.headers.value('content-range') ?? '';
        final m = RegExp(r'bytes\s+(\d+)-\d*/(\d+|\*)').firstMatch(range);
        if (m != null) {
          start = int.tryParse(m.group(1)!) ?? from;
          total = int.tryParse(m.group(2)!) ?? total;
        } else {
          start = from;
        }
        if (start > from) {
          // Server skipped ahead of what we have — can't splice that.
          Log.w(_tag, 'range start $start > have $from; restarting');
          cancel.cancel('bad range');
          _cancelToken = null;
          await _deleteQuietly(item.partPath);
          await _request(id, url, 0, depth + 1);
          return;
        }
      } else {
        final len = int.tryParse(response.headers.value('content-length') ?? '');
        if (len != null && len > 0) total = len;
        if (from > 0) Log.i(_tag, 'server ignored Range; restarting "${item.title}"');
      }

      final file = File(item.partPath);
      await file.parent.create(recursive: true);
      raf = await file.open(mode: FileMode.append);
      await raf.truncate(start);
      await raf.setPosition(start);
      written = start;

      // Free-space check is not available from dart:io; rely on write errors.
      _updateQuiet(id, (it) => it.copyWith(totalBytes: total, receivedBytes: written));
      _liveBytes = written;
      _emit();

      final buffer = Uint8List(_bufferSize);
      var fill = 0;
      await for (final chunk in response.data!.stream) {
        if (_disposed || _activeId != id || cancel.isCancelled) break;
        var off = 0;
        while (off < chunk.length) {
          final n = min(chunk.length - off, _bufferSize - fill);
          buffer.setRange(fill, fill + n, chunk, off);
          fill += n;
          off += n;
          if (fill == _bufferSize) {
            await raf.writeFrom(buffer, 0, fill);
            fill = 0;
          }
        }
        written += chunk.length;
        _liveBytes = written;
        _windowBytes += chunk.length;
        _lastByteAt = DateTime.now();
      }
      if (fill > 0) await raf.writeFrom(buffer, 0, fill);
      await raf.close();
      raf = null;

      if (_stalled) throw const _StallException();
      if (_disposed || _activeId != id || cancel.isCancelled) return;
      _cancelToken = null;
      _updateQuiet(id, (it) => it.copyWith(receivedBytes: written));

      final current = _find(id);
      if (current == null) return;
      if (current.totalBytes > 0 && written < current.totalBytes) {
        await _retry(id, 'connection ended at $written/${current.totalBytes}',
            progressed: written > from);
        return;
      }
      await _finish(id);
    } on FileSystemException catch (e) {
      await _closeQuietly(raf);
      if (_disposed || _activeId != id) return;
      final lowSpace = (e.osError?.errorCode ?? 0) == 28; // ENOSPC
      await _fail(
        id,
        lowSpace ? 'Not enough disk space' : 'Could not write the file: ${e.message}',
      );
    } catch (e) {
      // Everything else — DioException, SocketException, HttpException
      // ("Connection closed while receiving data"), TimeoutException, the
      // stall watchdog — is a network problem: resume from the .part.
      await _closeQuietly(raf);
      if (_disposed || _activeId != id) return;
      if (e is DioException && CancelToken.isCancel(e) && !_stalled) return;
      _cancelToken = null;
      final why = _stalled
          ? 'no data for 30 seconds'
          : e is DioException
              ? (e.message ?? e.type.name)
              : e.toString();
      await _retry(id, why, progressed: written > from, network: true);
    }
  }

  Future<void> _retry(
    String id,
    String why, {
    required bool progressed,
    bool network = false,
  }) async {
    if (_activeId != id) return;
    // Progress made on this attempt = the link works; start counting afresh.
    if (progressed) _retries = 0;
    // Offline: don't burn retries, wait for the network to return (with a
    // slow fallback poll in case the connectivity event never arrives).
    final offline = !_online;
    if (!offline) _retries++;
    if (_retries > consts.Downloads.maxRetries) {
      if (network) _netFailed.add(id);
      await _fail(id, why);
      return;
    }
    final ms = offline
        ? 30000
        : min(
            consts.Downloads.maxBackoff.inMilliseconds,
            1000 * (1 << min(4, max(0, _retries - 1))),
          );
    Log.i(_tag, 'retry $_retries for $id: $why in ${ms}ms');
    _speeds[id] = 0;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(milliseconds: ms), () {
      _retryTimer = null;
      if (_activeId != id || _disposed) return;
      unawaited(_attempt(id));
    });
    _emit();
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
          receivedBytes: it.totalBytes > 0 ? it.totalBytes : it.receivedBytes,
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
    if (_notifId == id) _notifId = null;
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

    _lease?.release();
    _lease = null;

    if (id != null) {
      final live = _liveBytes;
      _speeds.remove(id);
      _update(id, (it) => it.copyWith(
            status: nextStatus,
            receivedBytes: live >= 0 ? live : null,
          ));
    }
    _liveBytes = -1;
    _stopTickerIfIdle();
  }

  Future<void> _closeQuietly(RandomAccessFile? raf) async {
    if (raf == null) return;
    try {
      await raf.close();
    } catch (_) {}
  }

  // ---- Speed ticker / watchdog / notification -----------------------------

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

      final live = _liveBytes;
      if (live >= 0) _updateQuiet(id, (it) => it.copyWith(receivedBytes: live));

      // Stall watchdog: a connection that is open but silent is killed and
      // resumed instead of hanging forever.
      final token = _cancelToken;
      if (token != null &&
          !token.isCancelled &&
          now.difference(_lastByteAt) > _stallAfter) {
        Log.w(_tag, 'stalled; aborting to resume');
        _stalled = true;
        token.cancel('stalled');
      }
      _emit();
    });
  }

  void _stopTickerIfIdle() {
    if (_activeId != null) return;
    _ticker?.cancel();
    _ticker = null;
  }

  /// Keep the foreground service in step with the queue. Called on every
  /// emit (≈1/s while downloading, plus status changes).
  void _syncService() {
    if (_disposed) return;
    DownloadItem? shown;
    if (_activeId != null) shown = _find(_activeId!);
    shown ??= _items.firstWhereOrNull((it) =>
        it.status == DownloadStatus.waiting || it.status == DownloadStatus.queued);
    if (shown == null && _notifId != null) {
      final it = _find(_notifId!);
      if (it != null && it.status == DownloadStatus.paused) shown = it;
    }
    if (shown == null) {
      _notifId = null;
      unawaited(_service.stop());
      return;
    }
    _notifId = shown.id;
    final paused = shown.status == DownloadStatus.paused;
    final pct = (shown.progress * 100).floor();
    final queued = _items
        .where((it) =>
            it.id != shown!.id &&
            (it.status == DownloadStatus.queued || it.status == DownloadStatus.waiting))
        .length;
    String detail;
    if (paused) {
      detail = 'Paused';
    } else if (shown.status == DownloadStatus.waiting) {
      detail = 'Waiting for playback to finish';
    } else if (shown.status == DownloadStatus.queued) {
      detail = 'Queued';
    } else if (_retryTimer != null && _activeId == shown.id) {
      detail = _online ? 'Reconnecting…' : 'Waiting for network…';
    } else {
      final speed = speedOf(shown.id);
      detail = speed > 0 ? _fmtSpeed(speed) : 'Connecting…';
      if (shown.totalBytes > 0) {
        detail = '${_fmtBytes(shown.receivedBytes)} / ${_fmtBytes(shown.totalBytes)} · $detail';
      }
    }
    if (queued > 0) detail = '$detail · $queued more queued';
    unawaited(_service.show(
      id: shown.id,
      title: shown.subtitle.isNotEmpty && shown.isEpisode
          ? '${shown.title} — ${shown.subtitle}'
          : shown.title,
      percent: shown.totalBytes > 0 ? pct : -1,
      detail: detail,
      paused: paused,
    ));
  }

  static String _fmtSpeed(double bps) => '${_fmtBytes(bps.round())}/s';

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
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
    _syncService();
  }

  Future<void> dispose() async {
    await _stopActive(DownloadStatus.queued);
    _disposed = true;
    await _netSub?.cancel();
    await _service.stop();
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
