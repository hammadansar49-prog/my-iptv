import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'storage.dart';

/// License key gate for Android — talks to the SAME Firebase Realtime
/// Database the PC app (main.js) and theottdeals' own admin panel use, under
/// the same `iptv/` tree (`iptv/plans`, `iptv/settings`, `iptv/keys`,
/// `iptv/trials`, `iptv/trial_config`). One key system for both apps: a key
/// generated in the theottdeals admin panel activates on either the PC app
/// or this one, and each device claims its own slot in the key's
/// `machine_ids` map exactly like the PC app's `verifyKeyAgainstRtdb` does.
/// Deliberately no server of our own — same reasoning as main.js: these are
/// public client-safe config values, access control is enforced by RTDB's
/// own rules on `iptv/keys/$keyId` and `iptv/trials/$machineId`, not by
/// keeping this URL secret.
const String _rtdbUrl = 'https://theottdeals-reviews-default-rtdb.firebaseio.com';

class LicenseStatus {
  final bool valid;
  final bool isTrial;
  final String? plan;
  final int expiresAt; // epoch ms, 0 = invalid/none
  const LicenseStatus({required this.valid, this.isTrial = false, this.plan, this.expiresAt = 0});
  static const none = LicenseStatus(valid: false);
}

class LicensePlan {
  final String id;
  final String label;
  final num price;
  final String currency;
  final int durationDays;
  final String specs;
  const LicensePlan({required this.id, required this.label, required this.price, required this.currency, required this.durationDays, this.specs = ''});
  factory LicensePlan.fromJson(String id, Map data) => LicensePlan(
        id: id,
        label: (data['label'] ?? id).toString(),
        price: (data['price'] as num?) ?? 0,
        currency: (data['currency'] ?? 'PKR').toString(),
        durationDays: (data['duration_days'] as num?)?.toInt() ?? 0,
        specs: (data['specs'] ?? '').toString(),
      );

  // Same as formatPrice()/CURRENCY_SYMBOLS in the PC app's renderer.js: USD
  // shows "12$", everything else shows "1200 PKR" — kept in sync so the same
  // admin-set price reads identically on both apps.
  String get formattedPrice => currency == 'USD' ? '$price\$' : '$price $currency';

  String get periodLabel {
    if (durationDays <= 0) return '';
    if (durationDays % 365 == 0 && durationDays >= 365) {
      final y = durationDays ~/ 365;
      return y == 1 ? 'year' : '$y years';
    }
    if (durationDays % 30 == 0 && durationDays >= 30) {
      final m = durationDays ~/ 30;
      return m == 1 ? 'month' : '$m months';
    }
    if (durationDays % 7 == 0 && durationDays >= 7) {
      final w = durationDays ~/ 7;
      return w == 1 ? 'week' : '$w weeks';
    }
    return durationDays == 1 ? 'day' : '$durationDays days';
  }
}

class LicenseService {
  String? _machineId;

  // ---- warm cache: same reasoning as iptvLiveCache/subscribeRtdbSSE in the
  // PC app's main.js ("Pricing is live and instant, not hardcoded, no
  // 'Loading...' wait") — this screen used to read every value fresh from
  // RTDB on every open with a 15s timeout each, and main_shell.dart awaits
  // update-check -> announcement -> this paywall one after another, so on a
  // slow connection those waits stacked into the ~1 minute the user actually
  // hit. warmUp() fires all four reads in parallel right at app boot
  // (main.dart, non-blocking) so the cache is already warm by the time any
  // of these screens open; a cold cache still falls back to a live fetch,
  // just with a shorter timeout so a bad connection fails fast instead of
  // hanging for 15s per call.
  List<LicensePlan>? _plansCache;
  bool _plansLoaded = false;
  Map<String, dynamic>? _trialConfigCache;
  bool _trialConfigLoaded = false;
  Map<String, dynamic>? _announcementCache;
  bool _announcementLoaded = false;
  Map<String, dynamic>? _updateCache;
  bool _updateLoaded = false;

  Future<void> warmUp() async {
    await Future.wait([
      getPlans(force: true),
      getTrialConfig(force: true),
      getAnnouncement(force: true),
      checkForUpdate(force: true),
    ]);
  }

  // ---- live push: same trick as subscribeRtdbSSE in the PC app's main.js
  // ("an admin edit shows up while the screen is still open") — an open SSE
  // connection per node so a new announcement or a freshly published update
  // reaches this app the instant it's published, instead of only being
  // picked up the next time the app is cold-started. On any 'put'/'patch'
  // event from Firebase the node is just refetched (simplest correct thing;
  // no attempt to apply the patch locally) and the warm cache above is
  // refreshed — callers hear about it through the two broadcast streams
  // below.
  final _announcementUpdates = StreamController<Map<String, dynamic>?>.broadcast();
  final _updateUpdates = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>?> get announcementUpdates => _announcementUpdates.stream;
  Stream<Map<String, dynamic>> get updateUpdates => _updateUpdates.stream;
  bool _liveStarted = false;

  void startLiveUpdates() {
    if (_liveStarted) return;
    _liveStarted = true;
    _watchSse('/iptv/announcement', () async {
      final data = await getAnnouncement(force: true);
      if (!_announcementUpdates.isClosed) _announcementUpdates.add(data);
    });
    _watchSse('/iptv/update', () async {
      final data = await checkForUpdate(force: true);
      if (!_updateUpdates.isClosed) _updateUpdates.add(data);
    });
  }

  void stopLiveUpdates() {
    _liveStarted = false;
    _sseCancelled = true;
  }

  bool _sseCancelled = false;

  // Runs forever (until stopLiveUpdates()) reopening the SSE connection
  // whenever it drops — a stalled connection, the app going to the
  // background, or Firebase's own periodic reconnect are all normal and
  // expected here, not errors worth surfacing to the user. Backs off further
  // on each consecutive failed attempt (capped at 60s) instead of a fixed 5s
  // gap, so a device that genuinely can't reach RTDB for a while (offline,
  // captive portal, backgrounded under Doze) doesn't sit there redialing
  // every 5 seconds indefinitely.
  Future<void> _watchSse(String path, Future<void> Function() onChange) async {
    _sseCancelled = false;
    var failures = 0;
    while (!_sseCancelled) {
      http.Client? client;
      try {
        client = http.Client();
        final req = http.Request('GET', Uri.parse('$_rtdbUrl$path.json'));
        req.headers['Accept'] = 'text/event-stream';
        final res = await client.send(req);
        failures = 0;
        String? pendingEvent;
        await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (_sseCancelled) break;
          if (line.startsWith('event: ')) {
            pendingEvent = line.substring(7).trim();
          } else if (line.startsWith('data: ')) {
            if (pendingEvent == 'put' || pendingEvent == 'patch') {
              await onChange();
            }
            pendingEvent = null;
          }
        }
      } catch (_) {
        failures++;
        // network blip / backgrounded app — just reconnect below.
      } finally {
        client?.close();
      }
      if (_sseCancelled) break;
      final backoff = Duration(seconds: (5 * (failures == 0 ? 1 : failures)).clamp(5, 60));
      await Future.delayed(backoff);
    }
  }

  // Includes the Android ID (survives app reinstall, unlike anything this
  // app itself stores — resets only on factory reset) so the free-trial
  // one-per-device rule keeps pointing at the same hash after a reinstall,
  // matching the reasoning behind getMachineId() in main.js.
  Future<String> machineId() async {
    if (_machineId != null) return _machineId!;
    String androidId = '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      androidId = info.id;
    } catch (_) {}
    final raw = 'android|$androidId|${Platform.operatingSystemVersion}';
    _machineId = sha256.convert(utf8.encode(raw)).toString();
    return _machineId!;
  }

  // A reinstall (or a fresh install right after uninstalling) wipes this
  // app's own local storage — but iptv/trials/$machineId in RTDB is the
  // actual source of truth for "has this device already used its trial",
  // deliberately so a reinstall can't be used to grab a second one. That
  // same record is what was missing on the OTHER side of this: nothing ever
  // read it back to restore a trial that was genuinely still running, so a
  // user who reinstalled mid-trial landed back on the license gate with no
  // way in — checkTrialAvailability() correctly refused a new trial, but
  // nothing ever handed the still-valid one back to them. Called once at
  // boot (main.dart) before the license gate decides what to show; a no-op
  // if a valid license is already stored locally.
  Future<void> restoreTrialIfAny() async {
    if (localStatus().valid) return;
    try {
      final mid = await machineId();
      final row = await _rtdb('GET', '/iptv/trials/$mid', timeout: const Duration(seconds: 8));
      if (row == null) return;
      final map = Map<String, dynamic>.from(row);
      final expiresAt = (map['expires_at'] as num?)?.toInt() ?? 0;
      if (expiresAt > DateTime.now().millisecondsSinceEpoch) {
        await _writeLocal({'isTrial': true, 'plan': 'Free Trial', 'expiresAt': expiresAt});
      }
    } catch (_) {
      // offline right now — try again on the next boot.
    }
  }

  Future<dynamic> _rtdb(String method, String path, {Map<String, dynamic>? body, Duration timeout = const Duration(seconds: 15)}) async {
    final uri = Uri.parse('$_rtdbUrl$path.json');
    late http.Response res;
    final headers = {'Content-Type': 'application/json'};
    switch (method) {
      case 'GET':
        res = await http.get(uri).timeout(timeout);
        break;
      case 'PATCH':
        res = await http.patch(uri, headers: headers, body: jsonEncode(body)).timeout(timeout);
        break;
      case 'PUT':
        res = await http.put(uri, headers: headers, body: jsonEncode(body)).timeout(timeout);
        break;
      default:
        throw Exception('unsupported method');
    }
    if (res.body.isEmpty) return null;
    final data = jsonDecode(res.body);
    if (data is Map && data['error'] != null) throw Exception(data['error']);
    return data;
  }

  // ---- local persistence ----

  Map<String, dynamic>? _readLocal() {
    final raw = Storage.p.getString('license');
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLocal(Map<String, dynamic> lic) => Storage.p.setString('license', jsonEncode(lic));

  Future<void> clearLocal() => Storage.p.remove('license');

  LicenseStatus localStatus() {
    final lic = _readLocal();
    if (lic == null) return LicenseStatus.none;
    final expiresAt = (lic['expiresAt'] as num?)?.toInt() ?? 0;
    if (expiresAt == 0 || expiresAt <= DateTime.now().millisecondsSinceEpoch) return LicenseStatus.none;
    return LicenseStatus(valid: true, isTrial: lic['isTrial'] == true, plan: lic['plan'] as String?, expiresAt: expiresAt);
  }

  // ---- key verify/activate (same transition the RTDB rule allows from an
  // unauthenticated caller: unused -> active, and adding this device to
  // machine_ids up to max_devices) ----

  Future<Map<String, dynamic>> verifyKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return {'valid': false, 'reason': 'not-found'};
    try {
      final mid = await machineId();
      final row = await _rtdb('GET', '/iptv/keys/${Uri.encodeComponent(trimmed)}');
      if (row == null) return {'valid': false, 'reason': 'not-found'};
      final map = Map<String, dynamic>.from(row);
      if (map['status'] == 'revoked') return {'valid': false, 'reason': 'revoked'};
      final now = DateTime.now().millisecondsSinceEpoch;

      if (map['status'] == 'unused') {
        final durationDays = (map['duration_days'] as num?)?.toInt() ?? 30;
        final expiresAt = now + durationDays * 24 * 60 * 60 * 1000;
        await _rtdb('PATCH', '/iptv/keys/${Uri.encodeComponent(trimmed)}', body: {
          'status': 'active',
          'activated_at': now,
          'expires_at': expiresAt,
          'device_count': 1,
          'machine_ids/$mid': true,
        });
        await _writeLocal({'key': trimmed, 'plan': map['plan_label'], 'expiresAt': expiresAt, 'lastVerifiedAt': now});
        return {'valid': true, 'plan': map['plan_label'], 'expiresAt': expiresAt};
      }

      final expiresAt = (map['expires_at'] as num?)?.toInt() ?? 0;
      if (expiresAt != 0 && expiresAt < now) return {'valid': false, 'reason': 'expired'};

      final machineIds = Map<String, dynamic>.from(map['machine_ids'] ?? {});
      if (machineIds[mid] == true) {
        await _writeLocal({'key': trimmed, 'plan': map['plan_label'], 'expiresAt': expiresAt, 'lastVerifiedAt': now});
        return {'valid': true, 'plan': map['plan_label'], 'expiresAt': expiresAt};
      }

      final maxDevices = (map['max_devices'] as num?)?.toInt() ?? 1;
      final currentCount = (map['device_count'] as num?)?.toInt() ?? machineIds.length;
      if (currentCount >= maxDevices) return {'valid': false, 'reason': 'device-limit-reached'};

      await _rtdb('PATCH', '/iptv/keys/${Uri.encodeComponent(trimmed)}', body: {
        'device_count': currentCount + 1,
        'machine_ids/$mid': true,
      });
      await _writeLocal({'key': trimmed, 'plan': map['plan_label'], 'expiresAt': expiresAt, 'lastVerifiedAt': now});
      return {'valid': true, 'plan': map['plan_label'], 'expiresAt': expiresAt};
    } catch (e) {
      return {'valid': false, 'reason': 'network-error', 'error': e.toString()};
    }
  }

  // Cheap read-only re-check (no activation) — call every couple of minutes
  // while the app is open, same cadence as armLicenseWatch in the PC app's
  // renderer, so an admin revoke/expiry is caught without waiting for a
  // fresh app start.
  Future<void> recheckNow() async {
    final lic = _readLocal();
    if (lic == null || lic['isTrial'] == true) return;
    final key = lic['key'] as String?;
    if (key == null) return;
    try {
      final row = await _rtdb('GET', '/iptv/keys/${Uri.encodeComponent(key)}');
      if (row == null) { await _writeLocal({...lic, 'expiresAt': 0}); return; }
      final map = Map<String, dynamic>.from(row);
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = (map['expires_at'] as num?)?.toInt() ?? 0;
      if (map['status'] == 'revoked' || (expiresAt != 0 && expiresAt < now)) {
        await _writeLocal({...lic, 'expiresAt': 0});
      } else {
        await _writeLocal({...lic, 'plan': map['plan_label'], 'expiresAt': expiresAt, 'lastVerifiedAt': now});
      }
    } catch (_) {
      // offline — keep last known local state, same as the PC app.
    }
  }

  // ---- free trial: create-once per device, no row in iptv/keys at all,
  // same as trial:claim/trial:checkAvailability in main.js ----

  Future<Map<String, dynamic>> getTrialConfig({bool force = false}) async {
    if (!force && _trialConfigLoaded) return _trialConfigCache!;
    try {
      final data = await _rtdb('GET', '/iptv/trial_config', timeout: const Duration(seconds: 7));
      final map = data is Map ? Map<String, dynamic>.from(data) : {};
      final result = {
        'enabled': map['enabled'] != false,
        'durationHours': (map['duration_hours'] as num?)?.toInt() ?? 24,
        'specs': (map['specs'] ?? '').toString(),
      };
      _trialConfigCache = result;
      _trialConfigLoaded = true;
      return result;
    } catch (_) {
      if (_trialConfigLoaded) return _trialConfigCache!;
      return {'enabled': true, 'durationHours': 24, 'specs': ''};
    }
  }

  // Not cached the same way as the other reads (per-device claim status
  // needs to reflect a claim made moments ago, e.g. right after claimTrial())
  // — but it now reuses the already-warm trial_config instead of re-fetching
  // it, and the one live GET it still makes uses the same short timeout.
  Future<Map<String, dynamic>> checkTrialAvailability() async {
    try {
      final config = await getTrialConfig();
      if (config['enabled'] != true) return {'available': false, 'reason': 'disabled'};
      final mid = await machineId();
      final row = await _rtdb('GET', '/iptv/trials/$mid', timeout: const Duration(seconds: 7));
      if (row != null) return {'available': false, 'reason': 'already-claimed'};
      return {'available': true, 'config': config};
    } catch (e) {
      return {'available': false, 'reason': 'network-error'};
    }
  }

  Future<Map<String, dynamic>> claimTrial() async {
    try {
      final config = await getTrialConfig();
      if (config['enabled'] != true) return {'ok': false, 'reason': 'disabled'};
      final mid = await machineId();
      final existing = await _rtdb('GET', '/iptv/trials/$mid');
      if (existing != null) return {'ok': false, 'reason': 'already-claimed'};
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiresAt = now + (config['durationHours'] as int) * 60 * 60 * 1000;
      // RTDB rule (iptv/trials/$machineId, .write: "auth != null || !data.exists()")
      // lets this succeed exactly once per device — a second attempt after
      // a race loses to whichever write the server saw first.
      await _rtdb('PUT', '/iptv/trials/$mid', body: {'claimed_at': now, 'expires_at': expiresAt});
      await _writeLocal({'isTrial': true, 'plan': 'Free Trial', 'expiresAt': expiresAt});
      return {'ok': true, 'expiresAt': expiresAt};
    } catch (e) {
      return {'ok': false, 'reason': 'network-error'};
    }
  }

  // ---- plans / settings (live, admin-editable — read fresh every time,
  // same as license:getPlans/license:getSettings reading straight through
  // in the PC app, just without the in-memory cache since this screen is
  // only opened occasionally rather than kept warm for a whole session) ----

  Future<List<LicensePlan>> getPlans({bool force = false}) async {
    if (!force && _plansLoaded) return _plansCache!;
    try {
      final data = await _rtdb('GET', '/iptv/plans', timeout: const Duration(seconds: 7));
      final list = <LicensePlan>[];
      if (data is Map) {
        data.forEach((id, value) {
          if (value is Map && value['enabled'] == true) {
            list.add(LicensePlan.fromJson(id.toString(), value));
          }
        });
      }
      _plansCache = list;
      _plansLoaded = true;
      return list;
    } catch (_) {
      if (_plansLoaded) return _plansCache!;
      return [];
    }
  }

  Future<String?> getWhatsAppNumber() async {
    try {
      final data = await _rtdb('GET', '/iptv/settings');
      // Field is camelCase (`whatsappNumber`) — that's what the theottdeals
      // admin panel (admin-iptv.js) writes and what the PC app's renderer.js
      // reads. This used to look for `whatsapp_number` (snake_case), which
      // never existed in the node, so this always returned null and "Get
      // Package" silently failed to open WhatsApp on Android only.
      if (data is Map) return data['whatsappNumber']?.toString();
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---- in-app announcement, shared with the PC app (iptv/announcement in
  // RTDB) — same admin panel field, same content, either app can show it.
  // Read live (not cached) so a cold start can't race any warm-up fetch. ----

  Future<Map<String, dynamic>?> getAnnouncement({bool force = false}) async {
    if (!force && _announcementLoaded) return _announcementCache;
    try {
      final data = await _rtdb('GET', '/iptv/announcement', timeout: const Duration(seconds: 7));
      Map<String, dynamic>? result;
      if (data is Map && data['text'] != null && data['text'].toString().isNotEmpty) {
        final expiresAt = (data['expires_at'] as num?)?.toInt() ?? 0;
        if (expiresAt == 0 || expiresAt >= DateTime.now().millisecondsSinceEpoch) result = Map<String, dynamic>.from(data);
      }
      _announcementCache = result;
      _announcementLoaded = true;
      return result;
    } catch (_) {
      return _announcementLoaded ? _announcementCache : null;
    }
  }

  Future<bool> submitAnnouncementReview({required int rating, String comment = '', int? announcementCreatedAt}) async {
    try {
      final id = '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
      await _rtdb('PUT', '/iptv/announcement_reviews/$id', body: {
        'rating': rating.clamp(1, 5),
        'comment': comment.trim().length > 1000 ? comment.trim().substring(0, 1000) : comment.trim(),
        'announcement_created_at': announcementCreatedAt,
        'submitted_at': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- update check. SAME node the PC app reads (`iptv/update`), now
  // carrying a `platform` field the admin panel sets to "pc", "android" or
  // "all" — one update entry, admin picks who it's for, instead of two
  // separate always-on nodes. "pc" (or missing, for entries written before
  // this field existed) means PC-only; this app only ever surfaces
  // "android" or "all". Same plain numeric dotted-version comparison as
  // compareVersions() in main.js. ----

  int _compareVersions(String a, String b) {
    final pa = a.split('.').map((n) => int.tryParse(n) ?? 0).toList();
    final pb = b.split('.').map((n) => int.tryParse(n) ?? 0).toList();
    for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
      final da = i < pa.length ? pa[i] : 0;
      final db = i < pb.length ? pb[i] : 0;
      if (da != db) return da > db ? 1 : -1;
    }
    return 0;
  }

  Future<Map<String, dynamic>> checkForUpdate({bool force = false}) async {
    final info = await PackageInfo.fromPlatform();
    final currentVersion = info.version;
    if (!force && _updateLoaded) return {..._updateCache!, 'currentVersion': currentVersion};
    try {
      final data = await _rtdb('GET', '/iptv/update', timeout: const Duration(seconds: 7));
      Map<String, dynamic> result;
      if (data is! Map || data['version'] == null) {
        result = {'available': false};
      } else {
        final platform = (data['platform'] ?? 'pc').toString();
        if (platform != 'android' && platform != 'all') {
          result = {'available': false};
        } else {
          final latestVersion = data['version'].toString();
          final available = _compareVersions(latestVersion, currentVersion) > 0;
          result = {
            'available': available,
            'latestVersion': latestVersion,
            'downloadUrl': (data['download_url'] ?? '').toString(),
            'notes': (data['notes'] ?? '').toString(),
            'forceUpdate': available && data['force_update'] == true,
          };
        }
      }
      _updateCache = result;
      _updateLoaded = true;
      return {...result, 'currentVersion': currentVersion};
    } catch (_) {
      if (_updateLoaded) return {..._updateCache!, 'currentVersion': currentVersion};
      return {'available': false, 'currentVersion': currentVersion};
    }
  }

  Future<bool> openUpdateLink(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  Future<bool> openPlanOnWhatsApp(LicensePlan plan) async {
    final number = await getWhatsAppNumber();
    if (number == null || number.isEmpty) return false;
    final text = 'Hi, I want to get the "${plan.label}" package (${plan.formattedPrice} / ${plan.periodLabel}) for MY IPTV on Android.';
    final uri = Uri.parse('https://wa.me/$number?text=${Uri.encodeComponent(text)}');
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
