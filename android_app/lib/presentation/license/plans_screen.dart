import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/api/rtdb_api.dart';
import '../home/home_feed.dart';
import '../widgets/network_artwork.dart';
import 'license_state.dart';
import 'license_widgets.dart';

const _ribbonYellow = Color(0xFFFFB21F);

/// Paywall: poster header, feature hero, admin-priced plans from
/// `iptv/plans` (enabled only) and the free trial when this device can
/// still claim it.
class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key});

  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen> {
  String? _selectedId;
  bool _trialBusy = false;

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _activate(
      SubscriptionPlan plan, List<SubscriptionPlan> all) async {
    setState(() => _selectedId = plan.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ActivateDialog(plan: plan, allPlans: all),
    );
    if (ok == true && mounted) {
      final note = LicenseActions.lastActivationNote;
      _snack('${plan.label} activated.${note == null ? '' : ' $note'}');
    }
  }

  Future<void> _get(SubscriptionPlan plan) async {
    setState(() => _selectedId = plan.id);
    final err = await LicenseActions.openPlanOnWhatsApp(ref, plan);
    if (err != null && mounted) _snack(err);
  }

  Future<void> _contact() async {
    final err = await LicenseActions.contactOnWhatsApp(ref);
    if (err != null && mounted) _snack(err);
  }

  Future<void> _trial() async {
    setState(() => _trialBusy = true);
    final err = await LicenseActions.claimTrial(ref);
    if (!mounted) return;
    setState(() => _trialBusy = false);
    _snack(err ?? 'Free trial activated.');
    ref.invalidate(trialOfferProvider);
  }

  /// "BEST OFFER" for the longest plan, "POPULAR" for the second longest.
  Map<String, String> _ribbons(List<SubscriptionPlan> list) {
    final byLength = [...list]
      ..sort((a, b) => b.durationDays.compareTo(a.durationDays));
    return {
      if (byLength.isNotEmpty) byLength[0].id: 'BEST OFFER',
      if (byLength.length > 1) byLength[1].id: 'POPULAR',
    };
  }

  Widget _planList(
    AsyncValue<List<SubscriptionPlan>> plans,
    LicenseStatus status,
  ) {
    return plans.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(40),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text(
              'Could not load plans. Check your connection.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            TextButton(
              onPressed: () => ref.invalidate(plansProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No plans are available right now.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }
        final ribbons = _ribbons(list);
        return Column(
          children: [
            for (final p in list) ...[
              _buildCard(p, list, status, ribbons),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCard(
    SubscriptionPlan p,
    List<SubscriptionPlan> list,
    LicenseStatus status,
    Map<String, String> ribbons,
  ) {
    final active = status.activeNow &&
        !status.isTrial &&
        status.durationDays != null &&
        status.durationDays == p.durationDays;
    return _PlanCard(
      plan: p,
      active: active,
      selected: _selectedId == p.id,
      ribbon: active ? 'ACTIVE' : ribbons[p.id],
      onTap: () => setState(() => _selectedId = p.id),
      onActivate: () => _activate(p, list),
      onGet: () => _get(p),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(plansProvider);
    final status = ref.watch(licenseStatusProvider);
    final trial = ref.watch(trialOfferProvider).valueOrNull;
    final pad = MediaQuery.paddingOf(context);
    final headerH = MediaQuery.sizeOf(context).height * 0.3;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: () async {
          ref.invalidate(trialOfferProvider);
          return ref.refresh(plansProvider.future);
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Stack(
                children: [
                  _PosterStrip(height: headerH),
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, headerH - 70, 16, 0),
                    child: const _HeroCard(),
                  ),
                  Positioned(
                    top: pad.top + 4,
                    left: 4,
                    child: const BackButton(color: Colors.white),
                  ),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              sliver: SliverToBoxAdapter(child: _planList(plans, status)),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, pad.bottom + 24),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    if (trial != null) ...[
                      Text(
                        '${trial.durationHours} hours free trial',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _GlowPill(
                        label: 'Start For Free',
                        busy: _trialBusy,
                        onTap: _trial,
                      ),
                      const SizedBox(height: 18),
                    ],
                    TextButton.icon(
                      onPressed: _contact,
                      icon: const Icon(Icons.chat_rounded,
                          size: 16, color: AppColors.textTertiary),
                      label: const Text(
                        'Contact on WhatsApp',
                        style: TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 13,
                        ),
                      ),
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
}

/// Newest catalogue posters side by side, fading into black.
class _PosterStrip extends ConsumerWidget {
  const _PosterStrip({required this.height});

  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final newest = ref.watch(movieIndexProvider).valueOrNull?.newest ?? const [];
    final posters =
        newest.where((m) => (m.poster ?? '').isNotEmpty).take(5).toList();
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (posters.isEmpty)
            const ColoredBox(color: Color(0xFF1B0A10))
          else
            LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth / posters.length;
                return Row(
                  children: [
                    for (final m in posters)
                      NetworkArtwork(
                        url: m.poster,
                        width: w,
                        height: height,
                        fit: BoxFit.cover,
                      ),
                  ],
                );
              },
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.45, 1],
                colors: [
                  Color(0x33000000),
                  Color(0x66000000),
                  AppColors.background,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  // Every one of these exists in the app today.
  static const _features = [
    'Watch Movies, Series & Live TV',
    'Download & Watch Anytime',
    'Fast HD Streaming',
    'Continue Watching on Every Title',
    'Instant Updates & Announcements',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        color: const Color(0xE6141416),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: 'Stream Unlimited, Anytime\n',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      TextSpan(
                        text: 'Anywhere!',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF232326),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFFFFE08A), Color(0xFFE0A100)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Icon(Icons.workspace_premium_rounded,
                        size: 20, color: Color(0xFF6B4700)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final f in _features)
            Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded,
                        size: 14, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      f,
                      style: const TextStyle(
                        color: Color(0xFFE5E5EA),
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.active,
    required this.selected,
    required this.ribbon,
    required this.onTap,
    required this.onActivate,
    required this.onGet,
  });

  final SubscriptionPlan plan;
  final bool active;
  final bool selected;
  final String? ribbon;
  final VoidCallback onTap;
  final VoidCallback onActivate;
  final VoidCallback onGet;

  String get _per {
    final d = plan.durationDays;
    if (d <= 0) return '';
    if (d % 365 == 0) return d == 365 ? ' / Year' : ' / ${d ~/ 365} Years';
    if (d % 30 == 0) return d == 30 ? ' / Month' : ' / ${d ~/ 30} Months';
    return ' / ${formatPlanDuration(d)}';
  }

  String get _price {
    final c = plan.currency.trim().toUpperCase();
    if (c == 'PKR' || c == 'RS') return 'Rs ${plan.price}';
    return plan.priceLabel;
  }

  @override
  Widget build(BuildContext context) {
    const radius = 28.0;
    final r = ribbon;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: active || selected
                ? AppColors.accent
                : const Color(0xFF3A3A3C),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - 1),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(right: r == null ? 0 : 96),
                      child: Text(
                        plan.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_price$_per',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _CardButton(
                            label: 'Activate Plan',
                            background: Colors.white,
                            foreground: Colors.black,
                            onTap: onActivate,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _CardButton(
                            label: 'Get Plan',
                            background: const Color(0xFF141416),
                            foreground: Colors.white,
                            border: const Color(0xFF3A3A3C),
                            icon: Icons.chat_rounded,
                            onTap: onGet,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (r != null)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: active ? AppColors.accent : _ribbonYellow,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(16),
                      ),
                    ),
                    child: Text(
                      r,
                      style: TextStyle(
                        color: active ? Colors.white : Colors.black,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width accent pill with the login button's glow.
class _GlowPill extends StatelessWidget {
  const _GlowPill({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.45),
            blurRadius: 30,
            spreadRadius: 1,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: AppColors.accent,
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: busy ? null : onTap,
          customBorder: const StadiumBorder(),
          child: SizedBox(
            height: 58,
            width: double.infinity,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.icon,
    this.border,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final b = border;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: b == null ? BorderSide.none : BorderSide(color: b),
    );
    return Material(
      color: background,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: SizedBox(
          height: 46,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for the key, checks it belongs to [plan], then activates it.
class _ActivateDialog extends ConsumerStatefulWidget {
  const _ActivateDialog({required this.plan, required this.allPlans});

  final SubscriptionPlan plan;
  final List<SubscriptionPlan> allPlans;

  @override
  ConsumerState<_ActivateDialog> createState() => _ActivateDialogState();
}

class _ActivateDialogState extends ConsumerState<_ActivateDialog> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await LicenseActions.activateKeyForPlan(
        ref, _key.text, widget.plan, widget.allPlans);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1B1B1D),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Activate ${widget.plan.label}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Enter the licence key you received for this plan.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 18),
            LicenseKeyField(
              controller: _key,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              LicenseErrorText(_error!),
            ],
            const SizedBox(height: 20),
            GlowButton(
              label: 'Activate',
              busy: _busy,
              height: 52,
              onTap: _submit,
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
