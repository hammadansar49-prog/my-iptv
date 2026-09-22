import 'dart:math';

import '../../core/network/connection_guard.dart';
import '../../core/network/http_client.dart';
import '../../core/storage/secure_store.dart';
import '../../core/utils/logger.dart';
import '../../domain/repositories/repositories.dart';
import '../api/xtream_api.dart';
import '../models/account.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({
    required SecureStore secureStore,
    required HttpClient http,
    required ConnectionGuard guard,
  })  : _store = secureStore,
        _http = http,
        _guard = guard;

  static const _tag = 'AuthRepository';

  final SecureStore _store;
  final HttpClient _http;
  final ConnectionGuard _guard;

  Account? _active;
  XtreamSession? _session;
  XtreamApi? _api;

  @override
  Account? get activeAccount => _active;

  @override
  XtreamSession? get activeSession => _session;

  /// The API bound to the signed-in account. Null until sign-in succeeds.
  XtreamApi? get api => _api;

  @override
  Future<List<Account>> savedAccounts() async =>
      (await _store.readAccounts()).map(Account.fromJson).toList();

  @override
  Future<XtreamSession> signIn(Account account, {bool remember = true}) async {
    final api = XtreamApi(account: account, http: _http);

    // Authentication is one provider round trip; on a one-connection account
    // it must not race with anything else (AUDIT.md §3).
    final session = await _guard.withConnection(
      ProviderUse.probe,
      label: 'auth',
      (_) => api.authenticate(),
    );

    _active = account;
    _session = session;
    _api = api;

    // The account's real connection limit decides whether downloads may run
    // alongside playback. Never assume 1, never assume more.
    _guard.configure(maxConnections: session.userInfo.maxConnections);
    Log.i(_tag, 'signed in; max_connections=${session.userInfo.maxConnections}');

    if (remember) await _remember(account);
    await _store.writeActiveAccountId(account.id);
    return session;
  }

  Future<void> _remember(Account account) async {
    final saved = await savedAccounts();
    // Dedupe on (type, url, username) exactly as the PC app does, and move
    // the account to the front so the most recent login is first.
    final rest = saved.where((a) => !a.sameAs(account)).toList();
    final ordered = [account, ...rest];
    await _store.writeAccounts(ordered.map((a) => a.toJson()).toList());
  }

  @override
  Future<XtreamSession?> restoreSession() async {
    final accounts = await savedAccounts();
    if (accounts.isEmpty) return null;

    final activeId = await _store.readActiveAccountId();
    final account = accounts.firstWhere(
      (a) => a.id == activeId,
      orElse: () => accounts.first,
    );

    try {
      // There is no token in this system — the PC app replays the saved
      // credentials on every launch (AUDIT.md §4). Same here.
      return await signIn(account, remember: false);
    } catch (e) {
      Log.w(_tag, 'session restore failed: $e');
      // Leave the saved account in place: a transient network failure must
      // not silently wipe the user's playlist. The splash routes to login,
      // where the saved account is one tap away.
      return null;
    }
  }

  @override
  Future<void> removeAccount(String accountId) async {
    final remaining =
        (await savedAccounts()).where((a) => a.id != accountId).toList();
    await _store.writeAccounts(remaining.map((a) => a.toJson()).toList());
    if (_active?.id == accountId) await signOut();
  }

  @override
  Future<void> signOut() async {
    _active = null;
    _session = null;
    _api = null;
    await _store.writeActiveAccountId(null);
    _guard.configure(maxConnections: 1, allowConcurrentDownloads: false);
  }

  static String newAccountId() {
    final r = Random();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
