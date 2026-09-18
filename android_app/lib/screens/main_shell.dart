import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  StreamSubscription<Map<String, dynamic>?>? _annSub;
  StreamSubscription<Map<String, dynamic>>? _updSub;
  // Firebase resends the CURRENT value on every SSE (re)connect, not just on
  // an actual change — a network blip, the app resuming from background, or
  // the 5s backoff in LicenseService._watchSse can all trigger one. Without
  // this, that reconnect noise would reopen an update dialog the user
  // already saw or dismissed. Seeded from whatever the launch-time check
  // already showed, so a reconnect right after launch doesn't double-show it.
  String? _lastUpdateSignature;

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
        try {
          await maybeShowUpdate(context, license);
        } catch (_) {}
        if (!mounted) return;
        try {
          await maybeShowAnnouncement(context, license);
        } catch (_) {}
        try {
          await _maybeShowExpiryPaywall(license);
        } catch (_) {}
      });
      // Live push (see LicenseService.startLiveUpdates, armed once at app
      // boot in main.dart): an admin publishing a new announcement or update
      // while the app is already open reaches it within moments instead of
      // only being picked up on the next cold start.
      _annSub = license.announcementUpdates.listen((_) async {
        try { if (mounted) await maybeShowAnnouncement(context, license); } catch (_) {}
      });
      _updSub = license.updateUpdates.listen((result) async {
        try {
          final sig = _signatureOf(result);
          if (sig == _lastUpdateSignature) return;
          _lastUpdateSignature = sig;
          if (result['available'] == true && mounted) await maybeShowUpdate(context, license);
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    widget.state.downloads.removeListener(_onDownloadsChanged);
    _annSub?.cancel();
    _updSub?.cancel();
    super.dispose();
  }

  void _onDownloadsChanged() { if (mounted) setState(() {}); }

  String _signatureOf(Map<String, dynamic> r) => '${r['available']}|${r['latestVersion']}|${r['forceUpdate']}';

  DateTime? _lastBackPress;

  // Standard Android pattern: back from any other tab just jumps to Home
  // (matches the bottom nav's own idea of "home base"); a second back press
  // within 2s while already on Home is what actually exits the app — a
  // single back press on Home used to do nothing, no exit at all.
  void _handleBack() {
    if (tabIndex != 0) {
      setState(() => tabIndex = 0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPress != null && now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Press back again to exit'), duration: Duration(seconds: 2), backgroundColor: AppColors.bg3),
    );
  }

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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      body: IndexedStack(index: tabIndex, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        backgroundColor: AppColors.bg2,
        indicatorColor: AppColors.accent.withValues(alpha: .22),
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
      ),
    );
  }
}
