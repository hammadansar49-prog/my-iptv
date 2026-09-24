import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors/app_error.dart';
import '../../data/api/rtdb_api.dart';
import '../../data/models/json.dart';
import '../iptv_live/iptv_live_controller.dart';
import '../providers.dart';

/// What the gate, the Home badge and the Plans screen all read.
@immutable
class LicenseStatus {
  const LicenseStatus({
    required this.active,
    this.isTrial = false,
    this.expiresAt,
    this.durationDays,
    this.plan,
  });

  static const none = LicenseStatus(active: false);

  /// A valid, unexpired, not-revoked key or trial.
  final bool active;
  final bool isTrial;
  final DateTime? expiresAt;

  /// The active key's `duration_days` (null for trials / not yet known).
  final int? durationDays;
  final String? plan;

  /// Re-evaluated at call time: the badge ticks past expiry on its own.
  bool get activeNow {
    final exp = expiresAt;
    return active && (exp == null || exp.isAfter(DateTime.now()));
  }
}

/// Bumps on every [LicenseRepositoryImpl.changes] event (restore, verify,
/// trial claim, clear) so dependants rebuild instantly.
final _licenseRevisionProvider = StreamProvider<int>((ref) {
  var n = 0;
  return ref.watch(licenseRepositoryProvider).changes.map((_) => ++n);
});

/// Stored licence + live `iptv/keys/<key>` stream (revocation / extension).
final licenseStatusProvider = Provider<LicenseStatus>((ref) {
  ref.watch(_licenseRevisionProvider);
  final live = ref.watch(iptvLiveProvider);
  final repo = ref.watch(licenseRepositoryProvider);
  final v = repo.current;
  if (v == null || !v.valid || live.licenseBlocked) return LicenseStatus.none;

  final streamed = !v.isTrial && repo.key != null && live.streamedKey == repo.key;
  final liveExp = streamed ? live.liveKeyExpiresAt : null;
  final exp = liveExp != null
      ? DateTime.fromMillisecondsSinceEpoch(liveExp)
      : v.expiresAt;
  final status = LicenseStatus(
    active: true,
    isTrial: v.isTrial,
    expiresAt: exp,
    durationDays: streamed ? live.liveKeyDurationDays : null,
    plan: v.plan,
  );
  return status.activeNow ? status : LicenseStatus.none;
});

/// Trial offer shown on the gate and the Plans screen: null when the admin
/// disabled trials or this device already used its one.
final trialOfferProvider = FutureProvider.autoDispose<TrialConfig?>((ref) async {
  ref.watch(_licenseRevisionProvider);
  final repo = ref.watch(licenseRepositoryProvider);
  try {
    final config = await repo.trialConfig();
    if (!config.enabled) return null;
    return await repo.trialAvailable() ? config : null;
  } catch (_) {
    return null;
  }
});

final plansProvider =
    FutureProvider.autoDispose<List<SubscriptionPlan>>((ref) async {
  return ref.watch(licenseRepositoryProvider).plans();
});

/// Licence actions shared by the gate and the Plans screen. Each returns an
/// error message for the user, or null on success.
abstract final class LicenseActions {
  /// Extra line for the success message of the last activation (how many
  /// devices can still use a multi-device key), or null.
  static String? lastActivationNote;

  static Future<String?> activateKey(WidgetRef ref, String key) async {
    lastActivationNote = null;
    if (key.trim().isEmpty) return 'Enter your licence key.';
    final v = await ref.read(licenseRepositoryProvider).verify(key);
    if (v.valid) lastActivationNote = v.slotsNote;
    return v.valid ? null : v.userMessage;
  }

  /// Checks the key belongs to [plan] (same `duration_days`) before running
  /// the normal activation, so a 1 Month key is not "used up" on 1 Year.
  static Future<String?> activateKeyForPlan(
    WidgetRef ref,
    String key,
    SubscriptionPlan plan,
    List<SubscriptionPlan> allPlans,
  ) async {
    final trimmed = normalizeLicenseKey(key);
    if (trimmed.isEmpty) return 'Enter your licence key.';
    final Map<String, dynamic>? row;
    try {
      row = await ref.read(licenseRepositoryProvider).keyRow(trimmed);
    } on AppError {
      return const LicenseVerdict(valid: false, reason: 'network-error')
          .userMessage;
    }
    if (row == null) return LicenseVerdict.notFound.userMessage;
    final status = asString(row['status']);
    if (status == 'revoked') {
      return const LicenseVerdict(valid: false, reason: 'revoked').userMessage;
    }
    final exp = asInt(row['expires_at']);
    if (status != 'unused' &&
        exp > 0 &&
        exp < DateTime.now().millisecondsSinceEpoch) {
      return const LicenseVerdict(valid: false, reason: 'expired').userMessage;
    }
    final days = asInt(row['duration_days']);
    if (days != plan.durationDays) {
      final match = allPlans.where((p) => p.durationDays == days).firstOrNull;
      final keyPlan = match?.label ??
          asStringOrNull(row['plan_label']) ??
          '$days day${days == 1 ? '' : 's'}';
      return 'This key is for the $keyPlan plan, not ${plan.label}. '
          'Please activate it on the $keyPlan plan.';
    }
    return activateKey(ref, trimmed);
  }

  static Future<String?> claimTrial(WidgetRef ref) async {
    try {
      final v = await ref.read(licenseRepositoryProvider).claimTrial();
      return v.valid ? null : 'The free trial has already been used on this device.';
    } catch (_) {
      return 'Could not start the free trial. Check your connection and try again.';
    }
  }

  /// Plain support chat with the admin number from `iptv/settings`.
  static Future<String?> contactOnWhatsApp(WidgetRef ref) async {
    var number = ref.read(iptvLiveProvider).whatsappNumber;
    if (number == null || number.trim().isEmpty) {
      number =
          await ref.read(licenseRepositoryProvider).supportWhatsAppNumber();
    }
    final digits = (number ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return 'WhatsApp number is not set up yet — please try again later.';
    }
    final text = Uri.encodeComponent('Hi, I have a question about MY IPTV.');
    final ok = await launchUrl(
      Uri.parse('https://wa.me/$digits?text=$text'),
      mode: LaunchMode.externalApplication,
    );
    return ok ? null : 'Could not open WhatsApp.';
  }

  /// Port of renderer.js openPackageOnWhatsApp.
  static Future<String?> openPlanOnWhatsApp(
    WidgetRef ref,
    SubscriptionPlan plan,
  ) async {
    final live = ref.read(iptvLiveProvider);
    var number = live.whatsappNumber;
    var template = live.messageTemplate;
    if (number == null || number.trim().isEmpty) {
      try {
        final s = await ref.read(licenseRepositoryProvider).settings();
        number = asStringOrNull(s['whatsappNumber']) ??
            asStringOrNull(s['whatsapp']) ??
            asStringOrNull(s['whatsapp_number']);
        template ??= asStringOrNull(s['message_template']);
      } catch (_) {
        return 'Could not open WhatsApp — check your internet connection.';
      }
    }
    final digits = (number ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return 'WhatsApp number is not set up yet — please try again later.';
    }
    final message = (template?.trim().isNotEmpty ?? false
            ? template!
            : "Hi TheOTTDeals! 👋\n\nI'd like to activate the *MY IPTV {plan}* "
                '({price}, {duration}).\n\nPlease send me the activation '
                'details so I can get started.\n\nThank you!')
        .replaceAll('{plan}', plan.label)
        .replaceAll('{price}', plan.priceLabel)
        .replaceAll('{duration}', '${plan.durationDays} day(s)');
    final ok = await launchUrl(
      Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(message)}'),
      mode: LaunchMode.externalApplication,
    );
    return ok ? null : 'Could not open WhatsApp.';
  }
}

/// `HH:MM:SS` for a remaining duration (clamped at zero).
String formatCountdown(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

String formatPlanDuration(int days) {
  if (days <= 0) return '';
  if (days % 365 == 0) {
    final y = days ~/ 365;
    return '$y year${y == 1 ? '' : 's'}';
  }
  if (days % 30 == 0) {
    final m = days ~/ 30;
    return '$m month${m == 1 ? '' : 's'}';
  }
  return '$days day${days == 1 ? '' : 's'}';
}
