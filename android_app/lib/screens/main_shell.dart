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
      DownloadsTab(state: widget.state),
      ProfileTab(state: widget.state, onLoggedOut: () => setState(() {})),
    ];
    widget.state.downloads.addListener(_onDownloadsChanged);
  }

  @override
  void dispose() {
    widget.state.downloads.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onDownloadsChanged() { if (mounted) setState(() {}); }

  @override
  Widget build(BuildContext context) {
    final active = widget.state.downloads.items.any((d) => d.status == 'downloading');
    return Scaffold(
      body: IndexedStack(index: tabIndex, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        backgroundColor: AppColors.bg2,
        indicatorColor: AppColors.accent.withOpacity(.22),
        onDestinationSelected: (i) => setState(() => tabIndex = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          const NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'EPG'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: active,
              backgroundColor: const Color(0xFFEF4444),
              smallSize: 8,
              child: const Icon(Icons.download_outlined),
            ),
            selectedIcon: Badge(isLabelVisible: active, backgroundColor: const Color(0xFFEF4444), smallSize: 8, child: const Icon(Icons.download)),
            label: 'Downloads',
          ),
          const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}
