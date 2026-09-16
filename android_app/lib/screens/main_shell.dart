import 'package:flutter/material.dart';
import '../app_state.dart';
import '../license.dart';
import '../theme.dart';
import 'announcement_dialog.dart';
import 'update_dialog.dart';
import 'home_tab.dart';
import 'epg_tab.dart';
import 'downloads_tab.dart';
import 'profile_tab.dart';
import 'plans_sheet.dart';

/// The app's 4-tab shell: Home, EPG, Downloads, Profile — bottom navigation,
/// each tab kept alive in an IndexedStack so switching tabs never re-fetches.
class MainShell extends StatefulWidget {
  final AppState state;
  final LicenseService? license;
  const MainShell({super.key, required this.state, this.license});

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
      HomeTab(state: widget.state, license: widget.license),
      EpgTab(state: widget.state),
      DownloadsTab(state: widget.state),
      ProfileTab(state: widget.state, license: widget.license, onLoggedOut: () => setState(() {})),
    ];
    widget.state.downloads.addListener(_onDownloadsChanged);
    final license = widget.license;
    if (license != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await maybeShowUpdate(context, license);
        if (!mounted) return;
        await maybeShowAnnouncement(context, license);
        if (!mounted) return;
        await _maybeShowExpiryPaywall(license);
      });
    }
  }

  @override
  void dispose() {
    widget.state.downloads.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  void _onDownloadsChanged() { if (mounted) setState(() {}); }

  // Deliberately shows every single launch inside the last 3 days of a
  // key/trial's expiry (not just once) — the user explicitly asked for a
  // pop-up that keeps appearing "jab jab wo on kre" during that window, so
  // it's impossible to miss a package about to lapse. Outside that window
  // (or with no valid license, which the app-level gate already handles) it
  // stays silent.
  Future<void> _maybeShowExpiryPaywall(LicenseService license) async {
    final status = license.localStatus();
    if (!status.valid) return;
    final daysLeft = (status.expiresAt - DateTime.now().millisecondsSinceEpoch) / 86400000;
    if (daysLeft > 3) return;
    if (!mounted) return;
    await showPlansSheet(context, license);
  }

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
