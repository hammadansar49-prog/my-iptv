import 'json.dart';

enum AccountType { xtream, m3u }

/// A saved playlist/login. Mirrors the PC app's `store.accounts` entries,
/// except the password lives in the Android keystore (spec §7/§51).
class Account {
  const Account({
    required this.id,
    required this.type,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
  });

  final String id;
  final AccountType type;
  final String name;

  /// Trailing slashes stripped, exactly as `XtreamClient` does.
  final String url;

  final String username;
  final String password;

  factory Account.xtream({
    required String id,
    required String name,
    required String url,
    required String username,
    required String password,
  }) =>
      Account(
        id: id,
        type: AccountType.xtream,
        name: name,
        url: normaliseUrl(url),
        username: username,
        password: password,
      );

  static String normaliseUrl(String raw) {
    var u = raw.trim();
    u = u.replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !u.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      u = 'http://$u';
    }
    return u;
  }

  /// Dedupe identity — the PC app matches on (type, url, username).
  bool sameAs(Account other) =>
      type == other.type &&
      url.toLowerCase() == other.url.toLowerCase() &&
      username == other.username;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'name': name,
        'url': url,
        'username': username,
        'password': password,
      };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: asString(j['id']),
        type: asString(j['type']) == 'm3u' ? AccountType.m3u : AccountType.xtream,
        name: asString(j['name'], 'Playlist'),
        url: asString(j['url']),
        username: asString(j['username']),
        password: asString(j['password']),
      );
}

/// The `user_info` half of the Xtream auth response. These are the ONLY
/// subscription states that exist — spec §33 forbids inventing others.
class XtreamUserInfo {
  const XtreamUserInfo({
    required this.username,
    required this.status,
    required this.isAuthenticated,
    this.expiresAt,
    this.createdAt,
    this.maxConnections = 1,
    this.activeConnections = 0,
    this.isTrial = false,
  });

  final String username;

  /// Raw panel string: 'Active', 'Expired', 'Banned', 'Disabled', ...
  final String status;

  final bool isAuthenticated;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final int maxConnections;
  final int activeConnections;
  final bool isTrial;

  bool get isActive => status.toLowerCase() == 'active';

  bool get isExpired {
    final exp = expiresAt;
    return exp != null && exp.isBefore(DateTime.now());
  }

  factory XtreamUserInfo.fromJson(Map<String, dynamic> j) {
    final auth = j['auth'];
    return XtreamUserInfo(
      username: asString(j['username']),
      // A panel that omits status is treated as Active, matching the PC
      // app: it only rejects a status that is present AND not 'Active'.
      status: asStringOrNull(j['status']) ?? 'Active',
      isAuthenticated: !(auth == 0 || auth == '0'),
      expiresAt: asUnixSeconds(j['exp_date']),
      createdAt: asUnixSeconds(j['created_at']),
      maxConnections: asInt(j['max_connections'], 1).clamp(1, 99),
      activeConnections: asInt(j['active_cons']),
      isTrial: asBool(j['is_trial']),
    );
  }
}

/// The `server_info` half. Only used for display and for the timezone the
/// panel reports its EPG timestamps in.
class XtreamServerInfo {
  const XtreamServerInfo({this.url, this.timezone, this.serverProtocol});

  final String? url;
  final String? timezone;
  final String? serverProtocol;

  factory XtreamServerInfo.fromJson(Map<String, dynamic> j) => XtreamServerInfo(
        url: asStringOrNull(j['url']),
        timezone: asStringOrNull(j['timezone']),
        serverProtocol: asStringOrNull(j['server_protocol']),
      );
}

class XtreamSession {
  const XtreamSession({required this.userInfo, required this.serverInfo});

  final XtreamUserInfo userInfo;
  final XtreamServerInfo serverInfo;
}
