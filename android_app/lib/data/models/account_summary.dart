import 'json.dart';

/// Cached facts about a saved account, shown on the Accounts screen so a
/// card can display something useful without signing in to that account
/// first (which would cost a provider connection on a one-connection
/// panel — see AUDIT.md §3).
///
/// Everything here is recorded from a real response. A field we have never
/// observed stays null and the UI shows a placeholder rather than a made-up
/// number (spec §2: no fake data to make a screen look functional).
class AccountSummary {
  const AccountSummary({
    required this.accountId,
    this.username,
    this.status,
    this.expiresAt,
    this.streamCount,
    this.updatedAt,
  });

  final String accountId;

  /// From `user_info.username` at the last successful sign-in.
  final String? username;

  /// Raw panel status, e.g. 'Active'.
  final String? status;

  final DateTime? expiresAt;

  /// live + movies + series, recorded once the catalogue has actually been
  /// loaded. Null until then — we do not fetch three catalogues just to
  /// render a number.
  final int? streamCount;

  final DateTime? updatedAt;

  AccountSummary copyWith({
    String? username,
    String? status,
    DateTime? expiresAt,
    int? streamCount,
  }) =>
      AccountSummary(
        accountId: accountId,
        username: username ?? this.username,
        status: status ?? this.status,
        expiresAt: expiresAt ?? this.expiresAt,
        streamCount: streamCount ?? this.streamCount,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'username': username,
        'status': status,
        'expiresAt': expiresAt?.millisecondsSinceEpoch,
        'streamCount': streamCount,
        'updatedAt': updatedAt?.millisecondsSinceEpoch,
      };

  factory AccountSummary.fromJson(Map<String, dynamic> j) => AccountSummary(
        accountId: asString(j['accountId']),
        username: asStringOrNull(j['username']),
        status: asStringOrNull(j['status']),
        expiresAt: asUnixMillis(j['expiresAt']),
        streamCount: asIntOrNull(j['streamCount']),
        updatedAt: asUnixMillis(j['updatedAt']),
      );
}
