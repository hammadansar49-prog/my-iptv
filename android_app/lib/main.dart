import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app_state.dart';
import 'license.dart';
import 'notifications.dart';
import 'theme.dart';
import 'screens/announcement_dialog.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'screens/lock_screen.dart';
import 'screens/license_gate_screen.dart';
import 'widgets/floating_player.dart';

// Lets a tapped announcement notification reach the same dialog the app
// already shows on launch/live-push, even from a cold start — the
// notification tap callback in AppNotifications.init runs before MainShell
// (or any screen) necessarily exists yet, so it needs a route to a
// BuildContext that's independent of whatever's currently on screen.
final rootNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  // Required once, before any Player is created — sets up the bundled
  // libmpv native libraries the whole app's playback relies on.
  MediaKit.ensureInitialized();
  runApp(const IptvApp());
}

class IptvApp extends StatefulWidget {
  const IptvApp({super.key});

  @override
  State<IptvApp> createState() => _IptvAppState();
}

class _IptvAppState extends State<IptvApp> with WidgetsBindingObserver {
  final AppState appState = AppState();
  final LicenseService license = LicenseService();
  bool ready = false;
  bool loggedIn = false;
  bool locked = false;
  bool licensed = false;
  Timer? _licenseRecheckTimer;
  Timer? _expiryTimer;
  StreamSubscription? _keyRevokedSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _licenseRecheckTimer?.cancel();
    _expiryTimer?.cancel();
    _keyRevokedSub?.cancel();
    appState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock whenever the app comes back from the background, if a
    // passcode is set — matches how the reference screens describe it
    // ("Lock the app behind a passcode").
    if (state == AppLifecycleState.resumed && appState.passcode.isNotEmpty && loggedIn) {
      setState(() => locked = true);
    }
    if (state == AppLifecycleState.resumed && licensed) _recheckLicense();
  }

  Future<void> _boot() async {
    unawaited(license.warmUp());
    license.startLiveUpdates();
    unawaited(AppNotifications.init(onTapped: () {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) maybeShowAnnouncement(ctx, license);
    }));
    await appState.init();
    unawaited(appState.downloads.ensureStoragePermission());
    // Try auto-login with a hard 5s cap — on a slow connection the user
    // shouldn't stare at a spinner longer than this. Trial restore runs in
    // parallel so it doesn't add to the wait.
    await license.restoreTrialIfAny();
    await license.restoreKeyIfAny();
    try {
      await appState.tryAutoLogin().timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!mounted) return;
    final status = license.localStatus();
    setState(() {
      ready = true;
      licensed = status.valid;
      loggedIn = appState.client != null;
      locked = appState.client != null && appState.passcode.isNotEmpty;
    });
    if (status.valid) {
      _armLicenseWatch();
      _armExpiryTimer(status);
      _keyRevokedSub?.cancel();
      _keyRevokedSub = license.keyRevoked.listen((_) => _onKeyRevoked());
      license.startKeyWatcher();
    }
  }

  // Same cadence as armLicenseWatch in the PC app's renderer — catches a
  // revoke/expiry from the admin panel without needing a full restart.
  void _armLicenseWatch() {
    _licenseRecheckTimer?.cancel();
    _licenseRecheckTimer = Timer.periodic(const Duration(minutes: 2), (_) => _recheckLicense());
  }

  // Fires exactly when the license expires — no polling needed, instant redirect.
  void _armExpiryTimer(LicenseStatus status) {
    _expiryTimer?.cancel();
    final msLeft = status.expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (msLeft <= 0) return;
    _expiryTimer = Timer(Duration(milliseconds: msLeft), () {
      if (mounted && licensed) {
        setState(() => licensed = false);
        appState.closePlayer();
      }
    });
  }

  // Admin revoked the key from the panel — SSE caught it, now bounce to gate.
  void _onKeyRevoked() {
    if (mounted && licensed) {
      _licenseRecheckTimer?.cancel();
      _expiryTimer?.cancel();
      setState(() => licensed = false);
      appState.closePlayer();
    }
  }

  Future<void> _recheckLicense() async {
    await license.recheckNow();
    final status = license.localStatus();
    if (mounted && !status.valid && licensed) {
      _licenseRecheckTimer?.cancel();
      setState(() => licensed = false);
    }
  }

  void _onUnlocked() {
    final status = license.localStatus();
    setState(() => licensed = true);
    _armLicenseWatch();
    _armExpiryTimer(status);
    _keyRevokedSub?.cancel();
    _keyRevokedSub = license.keyRevoked.listen((_) => _onKeyRevoked());
    license.startKeyWatcher();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'MY IPTV',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // Floats the player above whatever route is currently showing (any
      // tab, or anything pushed on top of them) so it can stay mini and
      // playing while the user browses somewhere else — same reason it has
      // to live here, outside the app's own Navigator, rather than as a
      // pushed route. FloatingPlayer itself decides whether anything needs
      // an Overlay/Navigator ancestor (see the comment in that file) — kept
      // as a plain widget here so it stays a true no-op (SizedBox.shrink,
      // nothing intercepting touches) whenever no player is launched, e.g.
      // on the login/license screens.
      builder: (context, child) => Stack(
        children: [
          if (child != null) child,
          FloatingPlayer(state: appState),
        ],
      ),
      home: !ready
          ? const Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
            )
          : !licensed
              ? LicenseGateScreen(license: license, onUnlocked: _onUnlocked)
              : !loggedIn
                  ? LoginScreen(state: appState, license: license)
                  : locked
                      ? LockScreen(state: appState, onUnlocked: () => setState(() => locked = false))
                      : MainShell(state: appState, license: license),
    );
  }
}
