import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'advanced_settings_sheet.dart';

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
    // Reuse whatever Home/EPG have already fetched — only hit the network
    // for a section the user hasn't opened yet.
    final cache = widget.state.itemCache;
    setState(() {
      movies = cache['movies:all']?.length;
      series = cache['series:all']?.length;
      live = cache['live:all']?.length;
    });
    if (movies != null && series != null && live != null) return;

    setState(() => countsLoading = true);
    final client = widget.state.client!;
    try {
      final results = await Future.wait<List<PlayableItem>>([
        cache.containsKey('movies:all') ? Future.value(cache['movies:all']!) : client.getVodStreams(null),
        cache.containsKey('series:all') ? Future.value(cache['series:all']!) : client.getSeries(null),
        cache.containsKey('live:all') ? Future.value(cache['live:all']!) : client.getLiveStreams(null),
      ]);
      if (!mounted) return;
      cache['movies:all'] = results[0];
      cache['series:all'] = results[1];
      cache['live:all'] = results[2];
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

  void _refreshContent() {
    widget.state.itemCache.clear();
    widget.state.catCache.clear();
    _loadCounts();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Content will refresh next time you open Home / EPG.'), backgroundColor: AppColors.bg3),
    );
  }

  void _pickQuality() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Stream Format / Quality', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            ...{'auto': 'Auto (recommended)', '480': '480p', '720': '720p (HD)', '1080': '1080p (Full HD)', '2160': '4K (2160p)'}
                .entries
                .map((e) => ListTile(
                      title: Text(e.value),
                      trailing: widget.state.quality == e.key ? const Icon(Icons.check, color: AppColors.accent) : null,
                      onTap: () {
                        widget.state.setQuality(e.key);
                        Navigator.pop(context);
                      },
                    )),
          ],
        ),
      ),
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

  void _comingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming in a future update.'), backgroundColor: AppColors.bg3),
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
            decoration: BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
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
                  decoration: BoxDecoration(color: const Color(0xFF22C55E).withOpacity(.15), borderRadius: BorderRadius.circular(20)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle, size: 8, color: Color(0xFF22C55E)),
                    SizedBox(width: 5),
                    Text('Active', style: TextStyle(color: Color(0xFF22C55E), fontSize: 11, fontWeight: FontWeight.w600)),
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
              Expanded(child: _statCard(live, 'Live TV', const Color(0xFF22C55E))),
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
          const Text('Customize how the app fetches and plays your content.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
            child: Column(
              children: [
                _settingsRow(Icons.refresh, const Color(0xFF22C1C3), 'Refresh Content', 'Pull the latest movies, series and channels.', _refreshContent),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.smart_display_outlined, const Color(0xFFF59E0B), 'Stream Format', 'Pick the quality that plays best.', _pickQuality),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.tune, const Color(0xFF6366F1), 'Advanced Settings', 'Default player, Home layout and refresh.', _openAdvancedSettings),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.shield_outlined, const Color(0xFF22C55E), 'Security', 'Lock the app behind a passcode.', () => _comingSoon('App lock')),
                const Divider(height: 1, color: AppColors.border, indent: 68),
                _settingsRow(Icons.logout, const Color(0xFFEF4444), 'Logout', 'Sign out of this account on your device.', _logout, danger: true),
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
      decoration: BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
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
      title: Text(title, style: TextStyle(color: danger ? const Color(0xFFEF4444) : AppColors.text, fontWeight: FontWeight.w600, fontSize: 14)),
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
