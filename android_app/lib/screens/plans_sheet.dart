import 'package:flutter/material.dart';
import '../license.dart';
import '../license_key_formatter.dart';
import '../theme.dart';

/// The "Get Plans" paywall — same purpose as the license gate's "See Plans",
/// but full-screen with the layout the user asked to match: a glowing hero,
/// an overlapping feature card, plan rows with an auto-computed ribbon
/// (cheapest-per-day plan tagged POPULAR, a one-time/lifetime plan tagged
/// BEST OFFER, everything else shows its real % saved vs. the POPULAR row —
/// computed from the admin's own price/duration_days, never hardcoded), and
/// one big call-to-action at the bottom. Opened by tapping the PRO badge, and
/// (see maybeShowExpiryPaywall in main_shell.dart) automatically on launch
/// during a plan's last 3 days.
// Debounced the same way as AppState.launchPlayer: a fast double-tap on the
// PRO badge / "See Plans" button used to push this screen twice in the same
// frame, stacking two PaywallScreens (the second's own network calls firing
// against a route that was about to be covered) — on some devices that
// showed as the app crashing right on the plans screen. A single tap still
// opens instantly; a second tap within the window is dropped.
DateTime? _lastPlansOpen;

Future<void> showPlansSheet(BuildContext context, LicenseService license) {
  final now = DateTime.now();
  if (_lastPlansOpen != null && now.difference(_lastPlansOpen!) < const Duration(milliseconds: 800)) {
    return Future.value();
  }
  _lastPlansOpen = now;
  return Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => PaywallScreen(license: license),
  ));
}

class PaywallScreen extends StatefulWidget {
  final LicenseService license;
  const PaywallScreen({super.key, required this.license});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  bool loading = true;
  List<LicensePlan> plans = [];
  Map<String, dynamic>? trialAvailability;
  String? selectedId;
  bool busy = false;

  static const _features = [
    'Live TV, Movies & Series in one app',
    'Download & watch anytime, offline',
    'Works with Xtream Codes or M3U playlists',
    'Real-time pricing — always up to date',
    'One key, use it on your registered devices',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.license.getPlans(),
      widget.license.checkTrialAvailability(),
    ]);
    if (!mounted) return;
    final list = results[0] as List<LicensePlan>;
    setState(() {
      plans = list;
      trialAvailability = results[1] as Map<String, dynamic>;
      loading = false;
      if (list.isNotEmpty) selectedId = _ribbons(list).entries.firstWhere((e) => e.value == 'BEST OFFER', orElse: () => list.map((p) => MapEntry(p.id, '')).first).key;
    });
  }

  // Cheapest-per-day non-lifetime plan is the reference point ("POPULAR");
  // a lifetime/one-time plan (no real duration, or 10+ years) is always the
  // best long-run value ("BEST OFFER"); everything else shows its real
  // percentage saved against the reference per-day rate.
  Map<String, String> _ribbons(List<LicensePlan> list) {
    final out = <String, String>{};
    final timed = list.where((p) => p.durationDays > 0 && p.durationDays < 3650).toList();
    final lifetime = list.where((p) => p.durationDays <= 0 || p.durationDays >= 3650).toList();
    for (final p in lifetime) {
      out[p.id] = 'BEST OFFER';
    }
    if (timed.isEmpty) return out;
    timed.sort((a, b) => (a.price / a.durationDays).compareTo(b.price / b.durationDays));
    final baseline = timed.first;
    final baselinePerDay = baseline.price / baseline.durationDays;
    out[baseline.id] = lifetime.isEmpty ? 'BEST OFFER' : 'POPULAR';
    for (final p in timed.skip(1)) {
      final perDay = p.price / p.durationDays;
      final off = ((1 - perDay / baselinePerDay) * 100).round();
      if (off > 0) out[p.id] = '$off% OFF';
    }
    return out;
  }

  LicensePlan? get _selected => selectedId == null ? null : plans.where((p) => p.id == selectedId).firstOrNull;

  Future<void> _cta() async {
    final trial = trialAvailability;
    if (trial != null && trial['available'] == true) {
      setState(() => busy = true);
      final result = await widget.license.claimTrial();
      if (!mounted) return;
      setState(() => busy = false);
      if (result['ok'] == true) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Free trial started!')));
        return;
      }
    }
    final plan = _selected;
    if (plan == null) return;
    setState(() => busy = true);
    final ok = await widget.license.openPlanOnWhatsApp(plan);
    if (!mounted) return;
    setState(() => busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open WhatsApp. Please try again in a moment.")),
      );
    }
  }

  void _enterKey() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('Enter license key'),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [LicenseKeyFormatter()],
          style: const TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(hintText: 'MYIPTV-XXXXXX-XXXXXX-XXXXXX'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final key = controller.text.trim();
              Navigator.pop(context);
              if (key.isEmpty) return;
              final result = await widget.license.verifyKey(key);
              if (!mounted) return;
              if (result['valid'] == true) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Key activated!')));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That key could not be activated.')));
              }
            },
            child: const Text('Activate'),
          ),
        ],
      ),
    );
  }

  // Shared by the X button and the hardware back button, so both do exactly
  // the same thing — a plain Navigator.pop() looked like it "did nothing"
  // when tapped during the initial network load below, because the X button
  // used to only exist in the tree once loading finished; on a slow
  // connection that could be the better part of a minute with no way out.
  void _close() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Widget _closeButton() {
    return Positioned(
      top: 44,
      right: 14,
      child: IconButton(
        icon: Container(
          padding: const EdgeInsets.all(4),
          decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
          child: const Icon(Icons.close, color: Colors.white),
        ),
        onPressed: _close,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.license.localStatus();
    final ribbons = _ribbons(plans);
    final trial = trialAvailability;
    final trialOn = trial != null && trial['available'] == true;
    final trialHours = trialOn ? ((trial['config'] as Map?)?['durationHours'] as int? ?? 24) : 0;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
      backgroundColor: AppColors.bg,
      body: loading
          ? Stack(children: [const Center(child: CircularProgressIndicator(color: AppColors.accent)), _closeButton()])
          : Stack(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 140),
                  child: Column(
                    children: [
                      _buildHero(),
                      Transform.translate(
                        offset: const Offset(0, -60),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Column(
                            children: [
                              _buildFeatureCard(status),
                              const SizedBox(height: 18),
                              ...plans.map((p) => _buildPlanRow(p, ribbons[p.id])),
                              if (plans.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(top: 30),
                                  child: Text('No plans are available right now.', style: TextStyle(color: AppColors.textDim)),
                                ),
                              const SizedBox(height: 14),
                              if (trialOn)
                                Text(
                                  '$trialHours ${trialHours == 1 ? 'hour' : 'hours'} free trial, then continue with your selected plan',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                                )
                              else if (_selected != null)
                                Text(
                                  '${_selected!.formattedPrice} / ${_selected!.periodLabel}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _closeButton(),
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
                    decoration: const BoxDecoration(color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.border))),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: double.infinity, height: 52,
                          child: ElevatedButton(
                            onPressed: busy || (plans.isEmpty && !trialOn) ? null : _cta,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                            ),
                            child: busy
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Text(trialOn ? 'Start For Free' : 'Get Package', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('Privacy Policy', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                            const Text('  ·  ', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                            const Text('Terms of Use', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                            const Text('  ·  ', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                            GestureDetector(onTap: _enterKey, child: const Text('Have a key?', style: TextStyle(color: AppColors.textDim, fontSize: 11, decoration: TextDecoration.underline))),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  // Matches the black/red/gold reference the user picked out: a warm gold
  // glow behind the crown instead of the plain pink one, gold ribbons on the
  // plan rows (already in _buildPlanRow) and a gold-bordered CTA area — the
  // rest stays the app's own red accent so it still reads as this app, not a
  // reskin of someone else's screenshot.
  static const _gold = Color(0xFFF2A93B);

  Widget _buildHero() {
    return Container(
      height: 230,
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topCenter, radius: 1.1,
          colors: [Color(0xFF3A2A0E), AppColors.bg],
        ),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 64, height: 64,
        decoration: BoxDecoration(gradient: const LinearGradient(colors: [_gold, AppColors.accent2]), shape: BoxShape.circle),
        child: const Icon(Icons.workspace_premium, color: Colors.white, size: 34),
      ),
    );
  }

  Widget _buildFeatureCard(LicenseStatus status) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Stream Unlimited, Anytime', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const Text('Anywhere!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.accent)),
          const SizedBox(height: 14),
          if (status.valid)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                status.isTrial ? 'Free trial active · ends ${_fmtDate(status.expiresAt)}' : 'Current plan: ${status.plan ?? 'PRO'} · ends ${_fmtDate(status.expiresAt)}',
                style: const TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ..._features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Container(
                      width: 20, height: 20,
                      decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                      child: const Icon(Icons.check, size: 13, color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(f, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildPlanRow(LicensePlan plan, String? ribbon) {
    final selected = plan.id == selectedId;
    final ribbonColor = ribbon == 'BEST OFFER' ? const Color(0xFFF2A93B) : ribbon == 'POPULAR' ? const Color(0xFFF2A93B) : AppColors.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => setState(() => selectedId = plan.id),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                color: AppColors.bg2,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: selected ? AppColors.accent : AppColors.border, width: selected ? 1.6 : 1),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(plan.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text('${plan.formattedPrice} / ${plan.periodLabel}', style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                      ],
                    ),
                  ),
                  Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? AppColors.accent : AppColors.textDim),
                ],
              ),
            ),
            if (ribbon != null)
              Positioned(
                top: -8, right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: ribbonColor, borderRadius: BorderRadius.circular(10)),
                  child: Text(ribbon, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String _fmtDate(int epochMs) {
  if (epochMs == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
