import 'package:flutter/material.dart';
import 'app_state.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';

void main() {
  runApp(const IptvApp());
}

class IptvApp extends StatefulWidget {
  const IptvApp({super.key});

  @override
  State<IptvApp> createState() => _IptvAppState();
}

class _IptvAppState extends State<IptvApp> {
  final AppState appState = AppState();
  bool ready = false;
  bool loggedIn = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await appState.init();
    await appState.tryAutoLogin();
    setState(() {
      ready = true;
      loggedIn = appState.client != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: !ready
          ? const Scaffold(
              backgroundColor: AppColors.bg,
              body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
            )
          : loggedIn
              ? MainShell(state: appState)
              : LoginScreen(state: appState),
    );
  }
}
