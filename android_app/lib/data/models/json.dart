/// Defensive readers. Xtream panels are wildly inconsistent: ids come back as
/// ints on one panel and strings on another, numbers arrive as `""`, and
/// optional fields are simply absent. Spec §63: one missing optional field
/// must never crash the app.
library;

import 'dart:convert';

int? asIntOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t) ?? double.tryParse(t)?.toInt();
  }
  return null;
}

int asInt(Object? v, [int fallback = 0]) => asIntOrNull(v) ?? fallback;

double? asDoubleOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }
  return null;
}

String asString(Object? v, [String fallback = '']) {
  if (v == null) return fallback;
  if (v is String) return v;
  return v.toString();
}

String? asStringOrNull(Object? v) {
  final s = asString(v);
  return s.trim().isEmpty ? null : s;
}

bool asBool(Object? v, [bool fallback = false]) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (t == 'true' || t == '1' || t == 'yes') return true;
    if (t == 'false' || t == '0' || t == 'no' || t.isEmpty) return false;
  }
  return fallback;
}

/// Unix seconds (Xtream's `exp_date`, EPG `start_timestamp`) -> DateTime.
DateTime? asUnixSeconds(Object? v) {
  final n = asIntOrNull(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

/// Unix milliseconds (RTDB `expires_at`) -> DateTime.
DateTime? asUnixMillis(Object? v) {
  final n = asIntOrNull(v);
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n);
}

Map<String, dynamic> asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

List<Map<String, dynamic>> asMapList(Object? v) {
  if (v is List) {
    return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
  // Some panels return an object keyed by index instead of an array.
  if (v is Map) {
    return v.values.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
  return const [];
}

/// Xtream returns EPG titles/descriptions base64-encoded. A panel that does
/// not encode them must still work, so decoding is best-effort.
String decodeEpgText(Object? v) {
  final raw = asString(v);
  if (raw.isEmpty) return '';
  try {
    final normalised = raw.replaceAll(RegExp(r'\s'), '');
    if (normalised.length % 4 != 0) return raw;
    if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(normalised)) return raw;
    final bytes = base64.decode(normalised);
    final text = utf8.decode(bytes, allowMalformed: true);
    // If decoding produced control characters it was not base64 after all.
    if (text.contains(RegExp(r'[\x00-\x08\x0e-\x1f]'))) return raw;
    return text;
  } catch (_) {
    return raw;
  }
}
