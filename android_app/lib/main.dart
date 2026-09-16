import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';
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

Future<void> _ensureBatteryExemption() async {
  try {
    if (await Permission.ignoreBatteryOptimizations.isGranted) return;
    await Permission.ignoreBatteryOptimizations.request();
  } catch (_) {}
}

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
    license.startLiveUpdates();
    // Requests the notification permission right away rather than waiting
    // for the first announcement to exist — matches "ask when the app
    // opens" rather than "ask the first time it's actually needed".
    unawaited(AppNotifications.init(onTapped: () {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) maybeShowAnnouncement(ctx, license);
    }));
    await appState.init();
    // Same reasoning as the notification permission above, moved here from
    // "first download click" — asking while a movie is playing full-screen
    // popped a system dialog over the immersive video surface and left it
    // stuck on a white frame (audio kept playing underneath).
    unawaited(appState.downloads.ensureStoragePermission());
    // Same reasoning and same "ask once at boot, never mid-playback" rule as
    // the storage/notification prompts above — see the AndroidManifest.xml
    // comment on REQUEST_IGNORE_BATTERY_OPTIMIZATIONS for why this exists:
    // some OEM skins (found on a ColorOS/Oppo device) freeze the app's
    // process for a few seconds under normal background-management
    // heuristics, and if that freeze lands mid-gesture (e.g. tapping a movie
    // to play it) Android's own ANR watchdog can't tell the freeze apart
    // from a real hang and kills the app. Being on the OS's exemption list
    // is the standard mitigation. A no-op if already granted or the device
    // doesn't support it.
    unawaited(_ensureBatteryExemption());
    await appState.tryAutoLogin();
    // A reinstall wipes local storage, so a still-running trial needs to be
    // handed back from its RTDB record (see restoreTrialIfAny) before
    // deciding whether to show the license gate — otherwise a mid-trial
    // reinstall locked the user out with no trial offered (checkTrialAvailability
    // correctly refuses a second one) and no way back in either.
    await license.restoreTrialIfAny();
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
      navigatorKey: rootNavigatorKey,
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
