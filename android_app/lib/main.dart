import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app_state.dart';
import 'license.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'screens/lock_screen.dart';
import 'screens/license_gate_screen.dart';
import 'widgets/floating_player.dart';

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
    // Fired in parallel with app init, not awaited — by the time the user
    // reaches the license gate / plans screen / expiry paywall, plans,
    // trial config, the announcement and the update check are usually
    // already warm (see LicenseService.warmUp), instead of each of those
    // screens making its own fresh 15s-timeout RTDB round trip on open.
    // That stacking (update check -> announcement -> paywall, each awaited
    // in sequence in main_shell.dart) was the actual ~1 minute wait.
    unawaited(license.warmUp());
    await appState.init();
    await appState.tryAutoLogin();
    final status = license.localStatus();
    setState(() {
      ready = true;
      licensed = status.valid;
      loggedIn = appState.client != null;
      locked = loggedIn && appState.passcode.isNotEmpty;
    });
    if (status.valid) _armLicenseWatch();
  }

  // Same cadence as armLicenseWatch in the PC app's renderer — catches a
  // revoke/expiry from the admin panel without needing a full restart.
  void _armLicenseWatch() {
    _licenseRecheckTimer?.cancel();
    _licenseRecheckTimer = Timer.periodic(const Duration(minutes: 2), (_) => _recheckLicense());
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
    setState(() => licensed = true);
    _armLicenseWatch();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MY IPTV',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // Floats the player above whatever route is currently showing (any
      // tab, or anything pushed on top of them) so it can stay mini and
      // playing while the user browses somewhere else — same reason it has
      // to live here, outside the Navigator, rather than as a pushed route.
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
