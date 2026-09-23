import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/app.dart';
import '../../app/routes.dart';
import '../../data/api/rtdb_api.dart';
import '../../data/api/rtdb_stream.dart';
import '../../data/models/json.dart';
import '../../services/notifications/announcement_push.dart';
import '../../services/player/player_controller.dart';
import '../../core/utils/logger.dart';
import '../providers.dart';

/// Android counterpart of main.js's `iptvLiveCache` + `startLicenseStream`:
/// live RTDB state for the admin-controlled bits of the app (announcement,
/// update, WhatsApp number) and the stored licence's revocation/expiry.
///
/// Everything arrives over [RtdbStream] so an admin change lands in seconds,
/// not on the next launch. [IptvLiveLayer] renders what this exposes on top
/// of every route.
class IptvLiveController extends ChangeNotifier with WidgetsBindingObserver {
  IptvLiveController(this._ref);

  static const _tag = 'IptvLive';

  /// LocalStore key — the PC app keeps the same value in
  /// `settings.lastSeenAnnouncementAt`.
  static const _kSeenAnnouncement = 'lastSeenAnnouncementAt';

  final Ref _ref;
  final _streams = <RtdbStream>[];
  RtdbStream? _keyStream;
  String? _streamedKey;
  StreamSubscription<void>? _licenseSub;
  StreamSubscription<int?>? _tapSub;
  Timer? _expiryTimer;
  Timer? _announcementExpiry;
  bool _started = false;

  // ---- Public state --------------------------------------------------------

  /// The announcement to show now; null once dismissed/seen, expired or
  /// removed by the admin.
  Announcement? get announcement => _announcement;
  Announcement? _announcement;

  /// Latest applicable (android/all), newer-than-us update, if any.
  UpdateInfo? get update => _update;
  UpdateInfo? _update;
  bool _updateDismissed = false;

  bool get showUpdatePrompt =>
      _update != null && !_update!.forceUpdate && !_updateDismissed;
  bool get forceUpdate => _update != null && _update!.forceUpdate;

  String get currentVersion => _currentVersion;
  String _currentVersion = '';

  String? get whatsappNumber => _whatsappNumber;
  String? _whatsappNumber;

  /// Admin-editable WhatsApp message (`{plan}`/`{price}`/`{duration}`).
  String? get messageTemplate => _messageTemplate;
  String? _messageTemplate;

  /// Live `expires_at` / `duration_days` of the streamed stored key, so an
  /// admin extension shows up in the badge without a re-verify.
  int? get liveKeyExpiresAt => _liveKeyExpiresAt;
  int? _liveKeyExpiresAt;
  int? get liveKeyDurationDays => _liveKeyDurationDays;
  int? _liveKeyDurationDays;
  String? get streamedKey => _streamedKey;

  /// True while a stored licence is revoked/expired — drives the blocking
  /// "Subscription ended" screen. Lifts itself if the admin restores it.
  bool get licenseBlocked => _licenseBlocked;
  bool _licenseBlocked = false;

  // ---- Lifecycle -----------------------------------------------------------

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadVersion());

    _streams
      ..add(RtdbStream('/iptv/announcement', _onAnnouncement)..start())
      ..add(RtdbStream('/iptv/update', _onUpdate)..start())
      ..add(RtdbStream('/iptv/settings', _onSettings)..start());

    final license = _ref.read(licenseRepositoryProvider);
    _licenseSub = license.changes.listen((_) => _syncLicenseWatch());
    _syncLicenseWatch();

    // Notification taps (app was closed/backgrounded) must show the popup
    // even if it was already dismissed once.
    _tapSub = AnnouncementPush.taps.listen(_onNotificationTap);
    if (AnnouncementPush.hasPendingTap) {
      AnnouncementPush.hasPendingTap = false;
      _onNotificationTap(AnnouncementPush.pendingTap);
    }
    unawaited(AnnouncementPush.checkNativeTap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Android may have silently killed the sockets while backgrounded; the
    // watchdog would notice within ~75s, but a resume should be instant.
    for (final s in _streams) {
      s.reconnect();
    }
    _keyStream?.reconnect();
    // A timer does not fire while the process is frozen — re-check expiry.
    _syncLicenseWatch();
    unawaited(AnnouncementPush.checkNativeTap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _streams) {
      s.stop();
    }
    _keyStream?.stop();
    unawaited(_licenseSub?.cancel());
    unawaited(_tapSub?.cancel());
    _expiryTimer?.cancel();
    _announcementExpiry?.cancel();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    try {
      _currentVersion = (await PackageInfo.fromPlatform()).version;
    } catch (e) {
      Log.w(_tag, 'package info failed: $e');
    }
    // An update snapshot may have arrived before the version was known.
    _onUpdate(_rawUpdate);
  }

  // ---- Announcement --------------------------------------------------------

  Object? _rawAnnouncement;

  /// Set by a notification tap: bypasses the "seen once" rule for this
  /// created_at (or, when [_forceAny], for whatever is current).
  int? _forceShowAt;
  bool _forceAny = false;

  void _onNotificationTap(int? createdAt) {
    _forceShowAt = createdAt;
    _forceAny = createdAt == null;
    // If the stream already delivered it, re-evaluate now; otherwise the
    // first snapshot will.
    _onAnnouncement(_rawAnnouncement);
  }

  void _onAnnouncement(Object? raw) {
    _rawAnnouncement = raw;
    final ann = Announcement.fromRaw(raw);
    _announcementExpiry?.cancel();
    if (ann == null) {
      // Admin removed it (or it expired): close one that is open.
      _setAnnouncement(null);
      return;
    }
    final seen = _ref.read(localStoreProvider).read<num>(_kSeenAnnouncement);
    final forced = _forceAny || (_forceShowAt != null && ann.createdAt == _forceShowAt);
    if (!forced && ann.createdAt != null && seen != null && ann.createdAt! <= seen) {
      _setAnnouncement(null);
      return;
    }
    final exp = ann.expiresAt;
    if (exp != null) {
      final left = exp - DateTime.now().millisecondsSinceEpoch;
      _announcementExpiry =
          Timer(Duration(milliseconds: left.clamp(0, 1 << 31)), () => _setAnnouncement(null));
    }
    _setAnnouncement(ann);
  }

  void _setAnnouncement(Announcement? a) {
    _announcement = a;
    notifyListeners();
  }

  /// OK tapped. Records it as seen (so it shows once) and, when the admin
  /// asked for feedback and a star was picked, submits the review.
  Future<void> dismissAnnouncement({int rating = 0, String comment = ''}) async {
    final ann = _announcement;
    if (ann == null) return;
    _forceShowAt = null;
    _forceAny = false;
    _ref.read(localStoreProvider).write(
        _kSeenAnnouncement, ann.createdAt ?? DateTime.now().millisecondsSinceEpoch);
    _setAnnouncement(null);
    if (ann.collectFeedback && rating > 0) {
      try {
        await _ref.read(rtdbApiProvider).submitAnnouncementReview(
              rating: rating,
              comment: comment,
              announcementCreatedAt: ann.createdAt,
            );
      } catch (e) {
        // Same as the PC app: feedback is best-effort, never an error dialog.
        Log.w(_tag, 'review submit failed: $e');
      }
    }
  }

  // ---- Update --------------------------------------------------------------

  Object? _rawUpdate;

  void _onUpdate(Object? raw) {
    _rawUpdate = raw;
    final info = UpdateInfo.fromRaw(raw);
    final applies = info != null &&
        info.appliesToAndroid &&
        _currentVersion.isNotEmpty &&
        compareVersions(info.version, _currentVersion) > 0;
    final next = applies ? info : null;
    if (next?.version != _update?.version) _updateDismissed = false;
    _update = next;
    notifyListeners();
  }

  void dismissUpdatePrompt() {
    _updateDismissed = true;
    notifyListeners();
  }

  // ---- Settings ------------------------------------------------------------

  void _onSettings(Object? raw) {
    final s = asMap(raw);
    _whatsappNumber = asStringOrNull(s['whatsappNumber']) ??
        asStringOrNull(s['whatsapp']) ??
        asStringOrNull(s['whatsapp_number']);
    _messageTemplate = asStringOrNull(s['message_template']);
    notifyListeners();
  }

  // ---- Licence -------------------------------------------------------------

  /// Re-derive what to watch from the stored licence. No licence stored →
  /// nothing is watched and the app behaves as it always has.
  void _syncLicenseWatch() {
    final repo = _ref.read(licenseRepositoryProvider);
    final lic = repo.current;
    final key = repo.key;

    if (lic == null || !lic.valid) {
      _stopKeyStream();
      _expiryTimer?.cancel();
      _setBlocked(false);
      return;
    }

    if (lic.isTrial || key == null) {
      // A trial has no iptv/keys row: its local expiresAt is the whole story.
      _stopKeyStream();
      _armExpiry(lic.expiresAt?.millisecondsSinceEpoch);
      return;
    }

    // Cached expiry applies immediately (and offline); the stream then
    // corrects it with the server's truth.
    _armExpiry(lic.expiresAt?.millisecondsSinceEpoch);
    if (_streamedKey != key) {
      _stopKeyStream();
      _streamedKey = key;
      _keyStream = RtdbStream('/iptv/keys/${Uri.encodeComponent(key)}', _onKeyRow)..start();
    }
  }

  void _stopKeyStream() {
    _keyStream?.stop();
    _keyStream = null;
    _streamedKey = null;
    _liveKeyExpiresAt = null;
    _liveKeyDurationDays = null;
  }

  /// Same rule as main.js handleLicenseStreamEvent: a deleted row counts as
  /// revoked, and anything other than `active` with a future `expires_at`
  /// ends the subscription.
  void _onKeyRow(Object? raw) {
    if (raw is! Map) {
      _expiryTimer?.cancel();
      _setBlocked(true);
      return;
    }
    final status = asString(raw['status']);
    final exp = asInt(raw['expires_at']);
    final days = asIntOrNull(raw['duration_days']);
    if (exp != _liveKeyExpiresAt || days != _liveKeyDurationDays) {
      _liveKeyExpiresAt = exp > 0 ? exp : null;
      _liveKeyDurationDays = days;
      notifyListeners();
    }
    if (status != 'active' || exp <= 0) {
      _expiryTimer?.cancel();
      _setBlocked(true);
      return;
    }
    _armExpiry(exp);
  }

  /// Blocks now if [expiresAt] has passed, otherwise unblocks and sets a
  /// timer for the exact moment it does.
  void _armExpiry(int? expiresAt) {
    _expiryTimer?.cancel();
    if (expiresAt == null || expiresAt <= 0) {
      _setBlocked(false);
      return;
    }
    final left = expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) {
      _setBlocked(true);
      return;
    }
    _setBlocked(false);
    // Timer max is ~24 days on some platforms; resume re-arms anyway.
    _expiryTimer = Timer(Duration(milliseconds: left.clamp(0, 1 << 31)), () {
      if (DateTime.now().millisecondsSinceEpoch >= expiresAt) {
        _setBlocked(true);
      } else {
        _armExpiry(expiresAt);
      }
    });
  }

  void _setBlocked(bool blocked) {
    if (blocked == _licenseBlocked) return;
    _licenseBlocked = blocked;
    Log.i(_tag, 'license blocked=$blocked');
    if (blocked) unawaited(_haltEverything());
    notifyListeners();
  }

  /// Mirrors renderer.js armLicenseInvalidationPush: stop sound and the
  /// provider connection first, then get off any player route.
  Future<void> _haltEverything() async {
    try {
      await PlayerController.stopActive();
    } catch (e) {
      Log.w(_tag, 'stopActive failed: $e');
    }
    try {
      await _ref.read(downloadManagerProvider).pauseAll();
    } catch (e) {
      Log.w(_tag, 'pauseAll failed: $e');
    }
    final router = _ref.read(routerProvider);
    bool onPlayer() {
      final p = router.routerDelegate.currentConfiguration.uri.path;
      return p == Routes.player || p == Routes.liveTv;
    }

    var guard = 0;
    while (onPlayer() && router.canPop() && guard++ < 10) {
      router.pop();
    }
    if (onPlayer()) router.go(Routes.home);
  }
}

final iptvLiveProvider = ChangeNotifierProvider<IptvLiveController>((ref) {
  return IptvLiveController(ref)..start();
});
