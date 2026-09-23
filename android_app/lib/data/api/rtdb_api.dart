import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_error.dart';
import '../../core/utils/logger.dart';
import '../models/json.dart';

/// Result of verifying a license key. `reason` uses the exact strings
/// main.js produces so both apps and the admin panel agree.
class LicenseVerdict {
  const LicenseVerdict({
    required this.valid,
    this.reason,
    this.plan,
    this.expiresAt,
    this.isTrial = false,
  });

  final bool valid;

  /// not-found | revoked | expired | device-limit-reached | network-error
  final String? reason;

  final String? plan;
  final DateTime? expiresAt;
  final bool isTrial;

  static const notFound = LicenseVerdict(valid: false, reason: 'not-found');

  String get userMessage => switch (reason) {
        'not-found' => 'That key was not recognised.',
        'revoked' => 'This key has been revoked. Please contact support.',
        'expired' => 'Your subscription has expired. Please renew to continue.',
        'device-limit-reached' =>
          'This key is already in use on the maximum number of devices.',
        'network-error' =>
          'Could not reach the licensing server. Check your connection and try again.',
        _ => 'This key could not be verified.',
      };

  Map<String, dynamic> toJson() => {
        'valid': valid,
        'reason': reason,
        'plan': plan,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
        'isTrial': isTrial,
      };

  factory LicenseVerdict.fromJson(Map<String, dynamic> j) => LicenseVerdict(
        valid: asBool(j['valid']),
        reason: asStringOrNull(j['reason']),
        plan: asStringOrNull(j['plan']),
        expiresAt: asUnixMillis(j['expiresAt']),
        isTrial: asBool(j['isTrial']),
      );
}

class SubscriptionPlan {
  const SubscriptionPlan({
    required this.id,
    required this.label,
    required this.price,
    this.currency = '',
    this.specs = const [],
    this.enabled = true,
    this.durationDays = 0,
  });

  final String id;
  final String label;
  final String price;
  final String currency;
  final List<String> specs;
  final bool enabled;
  final int durationDays;

  factory SubscriptionPlan.fromJson(String id, Map<String, dynamic> j) {
    final rawSpecs = j['specs'];
    final specs = rawSpecs is List
        ? rawSpecs.map(asString).where((s) => s.isNotEmpty).toList()
        : asString(rawSpecs)
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
    return SubscriptionPlan(
      id: id,
      label: asString(j['label'], asString(j['name'], 'Plan')),
      price: asString(j['price']),
      currency: asString(j['currency']),
      specs: specs,
      enabled: asBool(j['enabled'], true),
      durationDays: asInt(j['duration_days']),
    );
  }
}

class TrialConfig {
  const TrialConfig({
    this.enabled = false,
    this.durationHours = 24,
    this.specs = const [],
  });

  final bool enabled;
  final int durationHours;
  final List<String> specs;

  factory TrialConfig.fromJson(Map<String, dynamic> j) {
    final rawSpecs = j['specs'];
    return TrialConfig(
      enabled: asBool(j['enabled']),
      durationHours: asInt(j['duration_hours'], 24),
      specs: rawSpecs is List
          ? rawSpecs.map(asString).where((s) => s.isNotEmpty).toList()
          : const [],
    );
  }
}

/// `iptv/announcement` as the theottdeals admin panel writes it.
class Announcement {
  const Announcement({
    required this.text,
    this.createdAt,
    this.expiresAt,
    this.collectFeedback = false,
  });

  final String text;

  /// Epoch millis. Doubles as the announcement's identity for "seen once".
  final int? createdAt;
  final int? expiresAt;
  final bool collectFeedback;

  /// Same rule as main.js refreshAnnouncement: no text or already expired
  /// means "no announcement".
  static Announcement? fromRaw(Object? raw) {
    if (raw is! Map) return null;
    final text = asString(raw['text']).trim();
    if (text.isEmpty) return null;
    final expires = asIntOrNull(raw['expires_at']);
    if (expires != null && expires > 0 &&
        expires < DateTime.now().millisecondsSinceEpoch) {
      return null;
    }
    return Announcement(
      text: text,
      createdAt: asIntOrNull(raw['created_at']),
      expiresAt: expires != null && expires > 0 ? expires : null,
      collectFeedback: asBool(raw['collect_feedback']),
    );
  }
}

/// `iptv/update` as the admin panel writes it.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    this.downloadUrl = '',
    this.notes = '',
    this.forceUpdate = false,
    this.platform = 'pc',
  });

  final String version;
  final String downloadUrl;
  final String notes;
  final bool forceUpdate;

  /// pc | android | all. Missing means "pc" (entries written before the
  /// selector existed), exactly as main.js's update:check reads it.
  final String platform;

  bool get appliesToAndroid => platform == 'android' || platform == 'all';

  static UpdateInfo? fromRaw(Object? raw) {
    if (raw is! Map) return null;
    final version = asString(raw['version']).trim();
    if (version.isEmpty) return null;
    return UpdateInfo(
      version: version,
      downloadUrl: asString(raw['download_url']).trim(),
      notes: asString(raw['notes']),
      forceUpdate: asBool(raw['force_update']),
      platform: asString(raw['platform'], 'pc'),
    );
  }
}

/// main.js compareVersions: plain numeric dotted comparison (no pre-release
/// suffixes in either app). A leading "v" and any "+build" are ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .trim()
      .replaceFirst(RegExp('^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((n) => int.tryParse(n.trim()) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < max(pa.length, pb.length); i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

/// Firebase Realtime Database REST client.
///
/// Plain HTTPS against `{base}{path}.json`, no SDK and no credentials — these
/// are the same client-safe public config values theottdeals' own
/// firebase-config.js ships to browsers. Access control is enforced by the
/// RTDB security rules, not by keeping the URL secret (AUDIT.md §6).
///
/// NOTE: CLAUDE.md records that the `iptv/keys/$keyId` rule permitting the
/// unauthenticated activation PATCH may not be deployed yet. If verification
/// fails with a permission error, that rule is the thing to check — do not
/// work around it client-side.
class RtdbApi {
  RtdbApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              validateStatus: (_) => true,
            ));

  static const _tag = 'RtdbApi';
  final Dio _dio;

  String get _base => Licensing.rtdbUrl;

  Future<Object?> _request(String method, String path, [Object? body]) async {
    final url = '$_base$path.json';
    try {
      final res = await _dio.request<String>(
        url,
        data: body == null ? null : jsonEncode(body),
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          headers: body == null ? null : {'Content-Type': 'application/json'},
        ),
      );
      final status = res.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw const AppError(
          AppErrorKind.server,
          'The licensing server refused the request.',
          detail: 'RTDB rules rejected this call — check iptv/keys rules are deployed',
        );
      }
      if (status < 200 || status >= 300) {
        throw AppError(
          AppErrorKind.server,
          'The licensing server is unavailable.',
          detail: 'HTTP $status $path',
          retryable: true,
        );
      }
      final text = (res.data ?? '').trim();
      if (text.isEmpty || text == 'null') return null;
      return jsonDecode(text);
    } on AppError {
      rethrow;
    } on DioException catch (e) {
      throw AppError.fromTransport(e.error ?? e, detail: e.message);
    }
  }

  // ---- Live config --------------------------------------------------------

  Future<List<SubscriptionPlan>> plans() async {
    final data = await _request('GET', '/iptv/plans');
    if (data is Map) {
      return data.entries
          .where((e) => e.value is Map)
          .map((e) => SubscriptionPlan.fromJson(
              e.key.toString(), (e.value as Map).cast<String, dynamic>()))
          .where((p) => p.enabled)
          .toList();
    }
    if (data is List) {
      final out = <SubscriptionPlan>[];
      for (var i = 0; i < data.length; i++) {
        final v = data[i];
        if (v is Map) {
          final p = SubscriptionPlan.fromJson('$i', v.cast<String, dynamic>());
          if (p.enabled) out.add(p);
        }
      }
      return out;
    }
    return const [];
  }

  Future<Map<String, dynamic>> settings() async =>
      asMap(await _request('GET', '/iptv/settings'));

  Future<TrialConfig> trialConfig() async =>
      TrialConfig.fromJson(asMap(await _request('GET', '/iptv/trial_config')));

  /// Fresh read, not the live cache — same reasoning as main.js update:check:
  /// an explicit "Check Updates" tap must not race the stream's first
  /// snapshot and wrongly say "up to date".
  Future<UpdateInfo?> update() async =>
      UpdateInfo.fromRaw(await _request('GET', '/iptv/update'));

  /// Port of main.js `announcement:submitReview` — same id format and body
  /// so the admin panel's reviews list reads both apps identically.
  Future<void> submitAnnouncementReview({
    required int rating,
    required String comment,
    int? announcementCreatedAt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rnd = Random.secure();
    final hex = List.generate(4, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final trimmed = comment.trim();
    await _request('PUT', '/iptv/announcement_reviews/${now}_$hex', {
      'rating': rating.clamp(1, 5),
      'comment': trimmed.length > 1000 ? trimmed.substring(0, 1000) : trimmed,
      'announcement_created_at': announcementCreatedAt,
      'submitted_at': now,
    });
  }

  // ---- Keys ---------------------------------------------------------------

  /// Port of `verifyKeyAgainstRtdb`. The step order is load-bearing and is
  /// documented in AUDIT.md §6 — in particular, a key's expiry clock starts
  /// at first successful verify, not at generation, so unsold keys do not
  /// expire sitting in inventory.
  Future<LicenseVerdict> verifyKey(String key, String machineId) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return LicenseVerdict.notFound;

    final path = '/iptv/keys/${Uri.encodeComponent(trimmed)}';
    final Object? raw;
    try {
      raw = await _request('GET', path);
    } on AppError catch (e) {
      Log.w(_tag, 'verify failed: ${e.detail ?? e.message}');
      return const LicenseVerdict(valid: false, reason: 'network-error');
    }
    if (raw is! Map) return LicenseVerdict.notFound;
    final row = raw.cast<String, dynamic>();

    if (asString(row['status']) == 'revoked') {
      return const LicenseVerdict(valid: false, reason: 'revoked');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final maxDevices = asInt(row['max_devices'], 1);
    final machineIds = asMap(row['machine_ids']);
    final plan = asStringOrNull(row['plan_label']);

    // 3. Unused -> activate, starting the clock now.
    if (asString(row['status']) == 'unused') {
      final days = asInt(row['duration_days']);
      final expiresAt = now + days * 24 * 60 * 60 * 1000;
      try {
        await _request('PATCH', path, {
          'status': 'active',
          'activated_at': now,
          'expires_at': expiresAt,
          'device_count': 1,
          'machine_ids/$machineId': true,
        });
      } on AppError catch (e) {
        Log.w(_tag, 'activation PATCH failed: ${e.detail ?? e.message}');
        return const LicenseVerdict(valid: false, reason: 'network-error');
      }
      return LicenseVerdict(
        valid: true,
        plan: plan,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      );
    }

    // 4. Expired.
    final expiresAt = asInt(row['expires_at']);
    if (expiresAt > 0 && expiresAt < now) {
      return const LicenseVerdict(valid: false, reason: 'expired');
    }

    // 5. Already claimed by this device.
    if (asBool(machineIds[machineId])) {
      return LicenseVerdict(
        valid: true,
        plan: plan,
        expiresAt: asUnixMillis(row['expires_at']),
      );
    }

    // 6/7. Claim a device slot if one is free.
    final currentCount = asInt(row['device_count'], machineIds.length);
    if (currentCount >= maxDevices) {
      return const LicenseVerdict(valid: false, reason: 'device-limit-reached');
    }
    try {
      await _request('PATCH', path, {
        'device_count': currentCount + 1,
        'machine_ids/$machineId': true,
      });
    } on AppError {
      return const LicenseVerdict(valid: false, reason: 'network-error');
    }
    return LicenseVerdict(
      valid: true,
      plan: plan,
      expiresAt: asUnixMillis(row['expires_at']),
    );
  }

  /// Port of `checkKeyStatusOnly`. Read-only by design: the frequent
  /// "did the admin revoke this?" poll must never consume a device slot.
  Future<LicenseVerdict> checkKeyStatus(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return LicenseVerdict.notFound;
    final Object? raw;
    try {
      raw = await _request('GET', '/iptv/keys/${Uri.encodeComponent(trimmed)}');
    } on AppError {
      return const LicenseVerdict(valid: false, reason: 'network-error');
    }
    if (raw is! Map) return LicenseVerdict.notFound;
    final row = raw.cast<String, dynamic>();
    if (asString(row['status']) == 'revoked') {
      return const LicenseVerdict(valid: false, reason: 'revoked');
    }
    final expiresAt = asInt(row['expires_at']);
    if (expiresAt > 0 && expiresAt < DateTime.now().millisecondsSinceEpoch) {
      return const LicenseVerdict(valid: false, reason: 'expired');
    }
    return LicenseVerdict(
      valid: true,
      plan: asStringOrNull(row['plan_label']),
      expiresAt: asUnixMillis(row['expires_at']),
    );
  }

  // ---- Trials -------------------------------------------------------------

  /// `iptv/trials/{machineId}` is create-once: the RTDB rule
  /// (`.write: "auth != null || !data.exists()"`) lets a device write it
  /// exactly once and never again, so reinstalling does not grant a second
  /// trial. The server record is authoritative, not anything stored locally.
  Future<bool> isTrialAvailable(String machineId) async {
    try {
      final existing = await _request('GET', '/iptv/trials/$machineId');
      return existing == null;
    } on AppError {
      // Offline: do not offer a trial we cannot record.
      return false;
    }
  }

  Future<LicenseVerdict> claimTrial(String machineId, TrialConfig config) async {
    if (!config.enabled) {
      return const LicenseVerdict(valid: false, reason: 'not-found');
    }
    final existing = await _request('GET', '/iptv/trials/$machineId');
    if (existing != null) {
      return const LicenseVerdict(valid: false, reason: 'not-found');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + config.durationHours * 60 * 60 * 1000;
    await _request('PUT', '/iptv/trials/$machineId', {
      'claimed_at': now,
      'expires_at': expiresAt,
    });
    return LicenseVerdict(
      valid: true,
      plan: 'Free Trial',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      isTrial: true,
    );
  }

  void close() => _dio.close(force: true);
}
