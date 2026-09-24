import 'dart:async';

import '../../core/constants/app_constants.dart';
import '../../core/security/device_identity.dart';
import '../../core/storage/secure_store.dart';
import '../../core/utils/logger.dart';
import '../../domain/repositories/repositories.dart';
import '../api/rtdb_api.dart';
import '../models/json.dart';

/// Subscription/license state.
///
/// Mirrors main.js: a verified key is cached locally with its expiry, the
/// server is re-checked at most once a day, and an offline check keeps the
/// last known good state rather than locking the user out (AUDIT.md §6).
class LicenseRepositoryImpl implements LicenseRepository {
  LicenseRepositoryImpl({
    required RtdbApi api,
    required SecureStore store,
    required DeviceIdentity identity,
  })  : _api = api,
        _store = store,
        _identity = identity;

  static const _tag = 'LicenseRepository';

  final RtdbApi _api;
  final SecureStore _store;
  final DeviceIdentity _identity;

  LicenseVerdict? _current;
  String? _key;
  DateTime? _lastChecked;

  /// Fires whenever the stored license changes (restored, verified,
  /// trial claimed, cleared) so the live watcher can (re)subscribe to the
  /// right `iptv/keys/<key>` stream without polling.
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  /// The stored key string; null for a trial or when nothing is stored.
  String? get key => _key;

  @override
  LicenseVerdict? get current => _current;

  @override
  bool get isLicensed {
    final v = _current;
    if (v == null || !v.valid) return false;
    final exp = v.expiresAt;
    return exp == null || exp.isAfter(DateTime.now());
  }

  /// Load the cached license at startup. Does not hit the network.
  Future<void> load() async {
    final saved = await _store.readLicense();
    if (saved == null) return;
    _key = asStringOrNull(saved['key']);
    _lastChecked = asUnixMillis(saved['lastVerifiedAt']);
    _current = LicenseVerdict.fromJson(saved);
    Log.i(_tag, 'restored license (trial=${_current?.isTrial})');
    _changes.add(null);
  }

  Future<void> _save() async {
    _changes.add(null);
    final v = _current;
    if (v == null || !v.valid) {
      await _store.writeLicense(null);
      return;
    }
    await _store.writeLicense({
      ...v.toJson(),
      'key': _key,
      'lastVerifiedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Future<LicenseVerdict> verify(String key) async {
    final machineId = await _identity.machineId();
    final verdict = await _api.verifyKey(key, machineId);
    if (verdict.valid) {
      _key = normalizeLicenseKey(key);
      _current = verdict;
      _lastChecked = DateTime.now();
      await _save();
    }
    return verdict;
  }

  /// Background revalidation. Cheap, read-only, and at most once a day —
  /// it must never consume a device slot, hence checkKeyStatus not verify.
  @override
  Future<LicenseVerdict> refresh() async {
    final v = _current;
    if (v == null) return LicenseVerdict.notFound;

    // A trial has no iptv/keys row at all; its local expiry is the whole
    // story (CLAUDE.md). Re-checking it against the server is meaningless.
    if (v.isTrial) {
      final exp = v.expiresAt;
      if (exp != null && exp.isBefore(DateTime.now())) {
        _current = const LicenseVerdict(valid: false, reason: 'expired');
        await _save();
      }
      return _current ?? v;
    }

    final last = _lastChecked;
    if (last != null &&
        DateTime.now().difference(last) < Licensing.revalidateInterval) {
      return v;
    }

    final key = _key;
    if (key == null) return v;

    final fresh = await _api.checkKeyStatus(key);
    if (fresh.reason == 'network-error') {
      // Offline: keep the last known good state rather than logging the
      // user out of an app they have paid for.
      Log.w(_tag, 'revalidation offline, keeping cached state');
      return v;
    }
    _current = fresh;
    _lastChecked = DateTime.now();
    await _save();
    return fresh;
  }

  /// Enabled plans, ordered by `sort_order` then duration (as the PC app).
  @override
  Future<List<SubscriptionPlan>> plans() async {
    final list = [...await _api.plans()];
    list.sort((a, b) {
      final o = a.sortOrder.compareTo(b.sortOrder);
      return o != 0 ? o : a.durationDays.compareTo(b.durationDays);
    });
    return list;
  }

  /// Read-only look at a key row (no activation, no device slot).
  Future<Map<String, dynamic>?> keyRow(String key) => _api.keyRow(key);

  /// `iptv/settings` — WhatsApp number and message template.
  Future<Map<String, dynamic>> settings() => _api.settings();

  @override
  Future<TrialConfig> trialConfig() => _api.trialConfig();

  /// A purchased key is active right now. A trial must never replace it.
  bool get _paidActive => _key != null && isLicensed;

  /// One trial per device, ever: checked on the server (survives reinstall)
  /// under the current id and the pre-ANDROID_ID one.
  Future<bool> _deviceTrialUnused() async {
    if (!await _api.isTrialAvailable(await _identity.machineId())) return false;
    final legacy = await _identity.legacyMachineId();
    if (legacy == null) return true;
    return _api.isTrialAvailable(legacy);
  }

  @override
  Future<bool> trialAvailable() async {
    if (isLicensed) return false;
    final config = await _api.trialConfig();
    if (!config.enabled) return false;
    return _deviceTrialUnused();
  }

  @override
  Future<LicenseVerdict> claimTrial() async {
    if (_paidActive || !await _deviceTrialUnused()) {
      return const LicenseVerdict(valid: false, reason: 'not-found');
    }
    final config = await _api.trialConfig();
    final verdict = await _api.claimTrial(await _identity.machineId(), config);
    if (verdict.valid) {
      _key = null;
      _current = verdict;
      _lastChecked = DateTime.now();
      await _save();
    }
    return verdict;
  }

  @override
  Future<String?> supportWhatsAppNumber() async {
    try {
      final settings = await _api.settings();
      return asStringOrNull(settings['whatsappNumber']) ??
          asStringOrNull(settings['whatsapp']) ??
          asStringOrNull(settings['whatsapp_number']);
    } catch (e) {
      Log.w(_tag, 'settings fetch failed: $e');
      return null;
    }
  }

  @override
  Future<void> clear() async {
    _current = null;
    _key = null;
    _lastChecked = null;
    _changes.add(null);
    await _store.writeLicense(null);
  }
}
