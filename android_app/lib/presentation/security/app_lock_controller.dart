import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/secure_store.dart';

/// The app-lock PIN, or null when locking is off. Loaded once at startup
/// (the splash awaits [load] the same way it awaits the license and the
/// session) so the very first frame already knows whether to route through
/// the lock screen — never a flash of unlocked content first.
class AppLockController extends StateNotifier<String?> {
  AppLockController(this._store) : super(null);

  final SecureStore _store;

  Future<void> load() async {
    state = await _store.readAppLockPin();
  }

  bool get isEnabled => state != null;

  Future<void> setPin(String pin) async {
    await _store.writeAppLockPin(pin);
    state = pin;
  }

  Future<void> disable() async {
    await _store.clearAppLockPin();
    state = null;
  }

  bool verify(String pin) => state != null && state == pin;
}
