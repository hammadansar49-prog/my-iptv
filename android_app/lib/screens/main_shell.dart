import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';
import 'home_tab.dart';
import 'epg_tab.dart';
import 'downloads_tab.dart';
import 'profile_tab.dart';

/// The app's 4-tab shell: Home, EPG, Downloads, Profile — bottom navigation,
/// each tab kept alive in an IndexedStack so switching tabs never re-fetches.
class MainShell extends StatefulWidget {
  final AppState state;
  const MainShell({super.key, required this.state});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int tabIndex = 0;
  late final List<Widget> tabs;

  @override
  void initState() {
    super.initState();
    tabs = [
      HomeTab(state: widget.state),
      EpgTab(state: widget.state),
      const DownloadsTab(),
      ProfileTab(state: widget.state, onLoggedOut: () => setState(() {})),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: tabIndex, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        backgroundColor: AppColors.bg2,
        indicatorColor: AppColors.accent.withOpacity(.25),
        onDestinationSelected: (i) => setState(() => tabIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'EPG'),
          NavigationDestination(icon: Icon(Icons.download_outlined), selectedIcon: Icon(Icons.download), label: 'Downloads'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}
