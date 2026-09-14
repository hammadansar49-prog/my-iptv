import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'advanced_settings_sheet.dart';
import 'security_sheet.dart';
import 'downloads_settings_sheet.dart';

class ProfileTab extends StatefulWidget {
  final AppState state;
  final VoidCallback onLoggedOut;
  const ProfileTab({super.key, required this.state, required this.onLoggedOut});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  int? movies;
  int? series;
  int? live;
  bool countsLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final cache = widget.state.itemCache;
    setState(() {
      movies = cache['movies:all']?.length;
      series = cache['series:all']?.length;
      live = cache['live:all']?.length;
    });
    if (movies != null && series != null && live != null) return;

    setState(() => countsLoading = true);
    try {
      final results = await Future.wait<List<PlayableItem>>([
        widget.state.sectionItems('movies'),
        widget.state.sectionItems('series'),
        widget.state.sectionItems('live'),
      ]);
      if (!mounted) return;
      setState(() {
        movies = results[0].length;
        series = results[1].length;
        live = results[2].length;
        countsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => countsLoading = false);
    }
  }

  Future<void> _logout() async {
    await widget.state.logout();
    if (!mounted) return;
    widget.onLoggedOut();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(state: widget.state)),
      (route) => false,
    );
  }

  Future<void> _refreshContent() async {
    await widget.state.refreshCatalog();
    setState(() {
      movies = series = live = null;
    });
    _loadCounts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Content will refresh next time you open Home / EPG.'), backgroundColor: AppColors.bg3),
    );
  }

  void _openAdvancedSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AdvancedSettingsSheet(state: widget.state),
    );
  }

  void _openDownloadsSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DownloadsSettingsSheet(state: widget.state),
    );
  }

  void _openSecurity() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SecuritySheet(state: widget.state),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acc = widget.state.activeAccount;
    final info = widget.state.authInfo?['user_info'] as Map?;
    final expDate = _tsToDate(info?['exp_date']);
    final createdAt = _tsToDate(info?['created_at']);
    final isTrial = '${info?['is_trial'] ?? '0'}' == '1';
    final maxCons = info?['max_connections']?.toString() ?? '-';
    final activeCons = info?['active_cons']?.toString() ?? '0';

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: cardDecoration(radius: 14),
            child: Row(
              children: [
                Container(
                  width: 52, height: 52,
                  decoration: const BoxDecoration(gradient: LinearGradient(colors: [AppColors.accent, AppColors.accent2]), shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text((acc?.username.isNotEmpty == true ? acc!.username[0] : '?').toUpperCase(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(acc?.username ?? acc?.name ?? '-', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(acc?.url ?? '', style: const TextStyle(color: AppColors.textDim, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: AppColors.success.withOpacity(.15), borderRadius: BorderRadius.circular(20)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle, size: 8, color: AppColors.success),
                    SizedBox(width: 5),
                    Text('Active', style: TextStyle(color: AppColors.success, fontSize: 11, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _statCard(movies, 'Movies', const Color(0xFFEF4444))),
              const SizedBox(width: 10),
              Expanded(child: _statCard(series, 'Series', const Color(0xFF3B82F6))),
              const SizedBox(width: 10),
              Expanded(child: _statCard(live, 'Live TV', AppColors.success)),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Account', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const Text('Your subscription at a glance.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10, mainAxisSpacing: 10,
            childAspectRatio: 2.3,
            children: [
              _infoCard(Icons.event_busy, 'Expires', expDate ?? '-'),
              _infoCard(Icons.timer_outlined, 'Trial', isTrial ? 'Yes' : 'No'),
              _infoCard(Icons.wifi_tethering, 'Connections', '$activeCons / $maxCons'),
              _infoCard(Icons.person_outline, 'Member since', createdAt ?? '-'),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Settings', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const Text('Customize how the app fetches, plays and downloads your content.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          const SizedBox(height: 10),
          Container(
            decoration: cardDecoration(radius: 14),
            child: Column(
              children: [
                _settingsRow(Icons.refresh, AppColors.tileCyan, 'Refresh Content', 'Pull the latest movies, series and channels.', _refreshContent),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.download_outlined, AppColors.tileOrange, 'Downloads', 'Where downloads are saved, and while-watching behaviour.', _openDownloadsSettings),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.tune, AppColors.tileIndigo, 'Advanced Settings', 'Home layout, resume, auto-next and live format.', _openAdvancedSettings),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.shield_outlined, AppColors.tileGreen, 'Security', 'Lock the app behind a passcode.', _openSecurity),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.logout, AppColors.tileRed, 'Logout', 'Sign out of this playlist on your device.', _logout, danger: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(int? value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(.3))),
      child: Column(
        children: [
          countsLoading && value == null
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_fmtCount(value), style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
        ],
      ),
    );
  }

  String _fmtCount(int? v) {
    if (v == null) return '-';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }

  Widget _infoCard(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: cardDecoration(radius: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: AppColors.textDim),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
          ]),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _settingsRow(IconData icon, Color color, String title, String subtitle, VoidCallback onTap, {bool danger = false}) {
    return ListTile(
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
      title: Text(title, style: TextStyle(color: danger ? AppColors.danger : AppColors.text, fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
      trailing: danger ? null : const Icon(Icons.chevron_right, color: AppColors.textDim),
      onTap: onTap,
    );
  }

  String? _tsToDate(dynamic ts) {
    if (ts == null) return null;
    final seconds = int.tryParse('$ts');
    if (seconds == null || seconds == 0) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]}, ${mo[d.month - 1]} ${d.day}, ${d.year}';
  }
}
