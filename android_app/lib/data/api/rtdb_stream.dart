import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';

/// A live view of one RTDB path over the REST streaming API — the Dart twin
/// of main.js `subscribeRtdbSSE`/`startLicenseStream`.
///
/// `GET <url>/<path>.json` with `Accept: text/event-stream` keeps the
/// connection open; RTDB first sends a `put` at `/` with the whole current
/// value, then a `put`/`patch` for every change. Unlike main.js (which
/// re-GETs the path on each event) the tree is patched locally from the
/// event payload: that saves a round trip, which is the difference between
/// "instant" and "a moment later" for revocation and announcements.
///
/// No SDK, no credentials — same public, rules-enforced access as
/// [RtdbApi]. Reconnects with backoff; a silent dead socket (common after
/// Android dozes the radio) is caught by a keep-alive watchdog, since RTDB
/// sends `keep-alive` roughly every 30s.
class RtdbStream {
  RtdbStream(this.path, this.onValue);

  /// e.g. `/iptv/announcement`. Must start with `/`.
  final String path;

  /// Called with the full current value (null = node absent) after the
  /// initial snapshot and after every change.
  final void Function(Object? value) onValue;

  static const _tag = 'RtdbStream';
  static const _watchdog = Duration(seconds: 75);

  HttpClient? _client;
  StreamSubscription<String>? _sub;
  Timer? _retryTimer;
  Timer? _watchdogTimer;
  Object? _value;
  int _failures = 0;
  bool _running = false;
  bool _connecting = false;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  void stop() {
    _running = false;
    _teardown();
  }

  /// Drop the current socket and connect again right away. Used on app
  /// resume, where the old socket may be dead without having errored.
  void reconnect() {
    if (!_running) return;
    _teardown();
    _failures = 0;
    unawaited(_connect());
  }

  void _teardown() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _client?.close(force: true);
    _client = null;
  }

  Future<void> _connect() async {
    if (!_running || _connecting) return;
    _connecting = true;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      _client = client;
      final req = await client.getUrl(Uri.parse('${Licensing.rtdbUrl}$path.json'));
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      final res = await req.close();
      if (!_running || _client != client) return;
      if (res.statusCode != 200) {
        Log.w(_tag, '$path HTTP ${res.statusCode}');
        await res.drain<void>().catchError((_) {});
        _scheduleRetry(permissionDenied: res.statusCode == 401 || res.statusCode == 403);
        return;
      }
      _petWatchdog();
      var buffer = '';
      _sub = res.transform(utf8.decoder).listen(
        (chunk) {
          _petWatchdog();
          buffer += chunk.replaceAll('\r\n', '\n');
          int idx;
          while ((idx = buffer.indexOf('\n\n')) != -1) {
            final raw = buffer.substring(0, idx);
            buffer = buffer.substring(idx + 2);
            _handleEvent(raw);
          }
        },
        onError: (Object e) {
          Log.w(_tag, '$path stream error: $e');
          _scheduleRetry();
        },
        onDone: _scheduleRetry,
        cancelOnError: true,
      );
    } catch (e) {
      Log.w(_tag, '$path connect failed: $e');
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _handleEvent(String raw) {
    String? event;
    String? data;
    for (final line in raw.split('\n')) {
      if (line.startsWith('event:')) event = line.substring(6).trim();
      if (line.startsWith('data:')) data = line.substring(5).trim();
    }
    switch (event) {
      case 'put':
      case 'patch':
        try {
          final payload = jsonDecode(data ?? 'null');
          if (payload is! Map) return;
          final segs = '${payload['path'] ?? '/'}'
              .split('/')
              .where((s) => s.isNotEmpty)
              .toList();
          _value = event == 'put'
              ? _setAt(_value, segs, payload['data'])
              : _patchAt(_value, segs, payload['data']);
          _failures = 0;
          onValue(_value);
        } catch (e) {
          // Malformed event — the next one (or the reconnect snapshot)
          // brings the tree back in line.
          Log.w(_tag, '$path bad event: $e');
        }
      case 'keep-alive':
        break;
      case 'cancel':
        // Rules now deny this read. Retry slowly in case they change back.
        Log.w(_tag, '$path cancelled by server: $data');
        _scheduleRetry(permissionDenied: true);
      case 'auth_revoked':
        _scheduleRetry();
    }
  }

  void _petWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(_watchdog, () {
      Log.w(_tag, '$path went silent, reconnecting');
      reconnect();
    });
  }

  void _scheduleRetry({bool permissionDenied = false}) {
    if (!_running || _retryTimer != null) return;
    _teardown();
    _failures++;
    // 1s, 2s, 4s … capped at 30s; a rules rejection waits a full minute.
    final delay = permissionDenied
        ? const Duration(seconds: 60)
        : Duration(seconds: min(30, 1 << min(_failures - 1, 5)));
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_connect());
    });
  }

  static Object? _setAt(Object? root, List<String> segs, Object? data) {
    if (segs.isEmpty) return data;
    final map = root is Map ? Map<String, dynamic>.from(root) : <String, dynamic>{};
    final child = _setAt(map[segs.first], segs.sublist(1), data);
    if (child == null) {
      map.remove(segs.first);
    } else {
      map[segs.first] = child;
    }
    return map.isEmpty ? null : map;
  }

  static Object? _patchAt(Object? root, List<String> segs, Object? data) {
    if (data is! Map) return _setAt(root, segs, data);
    var out = root;
    for (final e in data.entries) {
      out = _setAt(out, [...segs, ...'${e.key}'.split('/').where((s) => s.isNotEmpty)], e.value);
    }
    return out;
  }
}
