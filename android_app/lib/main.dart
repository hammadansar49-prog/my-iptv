import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app_state.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'screens/lock_screen.dart';

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
  bool ready = false;
  bool loggedIn = false;
  bool locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
  }

  Future<void> _boot() async {
    await appState.init();
    await appState.tryAutoLogin();
    setState(() {
      ready = true;
      loggedIn = appState.client != null;
      locked = loggedIn && appState.passcode.isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MY IPTV',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: !ready
          ? const Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
            )
          : !loggedIn
              ? LoginScreen(state: appState)
              : locked
                  ? LockScreen(state: appState, onUnlocked: () => setState(() => locked = false))
                  : MainShell(state: appState),
    );
  }
}
