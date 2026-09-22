import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_error.dart';
import '../../data/models/account.dart';
import '../../data/repositories/auth_repository_impl.dart';
import '../providers.dart';

enum AuthPhase { unknown, signedOut, signingIn, signedIn }

class AuthState {
  const AuthState({
    this.phase = AuthPhase.unknown,
    this.session,
    this.account,
    this.error,
    this.savedAccounts = const [],
  });

  final AuthPhase phase;
  final XtreamSession? session;
  final Account? account;
  final AppError? error;
  final List<Account> savedAccounts;

  bool get isBusy => phase == AuthPhase.signingIn;
  bool get isSignedIn => phase == AuthPhase.signedIn && session != null;

  AuthState copyWith({
    AuthPhase? phase,
    XtreamSession? session,
    Account? account,
    AppError? error,
    bool clearError = false,
    List<Account>? savedAccounts,
  }) =>
      AuthState(
        phase: phase ?? this.phase,
        session: session ?? this.session,
        account: account ?? this.account,
        error: clearError ? null : (error ?? this.error),
        savedAccounts: savedAccounts ?? this.savedAccounts,
      );
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._ref) : super(const AuthState());

  final Ref _ref;

  AuthRepositoryImpl get _repo => _ref.read(authRepositoryProvider);

  Future<void> loadSavedAccounts() async {
    final accounts = await _repo.savedAccounts();
    if (!mounted) return;
    state = state.copyWith(savedAccounts: accounts);
  }

  /// Splash path: try the stored credentials, fall through to login on any
  /// failure. Never throws — the splash must always resolve (spec §8).
  Future<bool> restore() async {
    try {
      final session = await _repo.restoreSession();
      if (!mounted) return false;
      if (session == null) {
        state = state.copyWith(phase: AuthPhase.signedOut);
        await loadSavedAccounts();
        return false;
      }
      _ref.read(sessionProvider.notifier).state = session;
      state = state.copyWith(
        phase: AuthPhase.signedIn,
        session: session,
        account: _repo.activeAccount,
        clearError: true,
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      state = state.copyWith(phase: AuthPhase.signedOut);
      await loadSavedAccounts();
      return false;
    }
  }

  Future<bool> signIn({
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    final account = Account.xtream(
      id: AuthRepositoryImpl.newAccountId(),
      name: name.trim().isEmpty ? username.trim() : name.trim(),
      url: url,
      username: username.trim(),
      password: password,
    );
    return signInWith(account);
  }

  Future<bool> signInWith(Account account) async {
    if (!mounted) return false;
    state = state.copyWith(phase: AuthPhase.signingIn, clearError: true);
    try {
      final session = await _repo.signIn(account);
      if (!mounted) return false;
      _ref.read(sessionProvider.notifier).state = session;
      state = state.copyWith(
        phase: AuthPhase.signedIn,
        session: session,
        account: account,
        clearError: true,
      );
      await loadSavedAccounts();
      return true;
    } on AppError catch (e) {
      if (!mounted) return false;
      state = state.copyWith(phase: AuthPhase.signedOut, error: e);
      return false;
    } catch (e) {
      if (!mounted) return false;
      state = state.copyWith(
        phase: AuthPhase.signedOut,
        error: AppError.fromTransport(e),
      );
      return false;
    }
  }

  Future<void> removeAccount(String id) async {
    await _repo.removeAccount(id);
    await loadSavedAccounts();
  }

  Future<void> signOut() async {
    await _repo.signOut();
    if (!mounted) return;
    _ref.read(sessionProvider.notifier).state = null;
    state = const AuthState(phase: AuthPhase.signedOut);
    await loadSavedAccounts();
  }

  void clearError() {
    if (!mounted) return;
    state = state.copyWith(clearError: true);
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));
