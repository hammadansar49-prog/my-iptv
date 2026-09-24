import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import 'license_state.dart';
import 'license_widgets.dart';

/// Licence gate between the catalogue load and Accounts/Home. Shown only
/// when there is no valid key or trial; leaves on its own the moment one
/// becomes active (here, on the Plans screen above it, or from the admin).
class LicenseScreen extends ConsumerStatefulWidget {
  const LicenseScreen({super.key, required this.next});

  /// Where the flow continues once licensed.
  final String next;

  @override
  ConsumerState<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends ConsumerState<LicenseScreen> {
  static const _bg = Color(0xFF151516);

  final _key = TextEditingController();
  bool _busy = false;
  bool _trialBusy = false;
  String? _error;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ref.read(licenseStatusProvider).activeNow) _continue();
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _continue() {
    if (_left || !mounted) return;
    _left = true;
    context.go(widget.next);
  }

  Future<void> _activate() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await LicenseActions.activateKey(ref, _key.text);
    if (!mounted) return;
    if (err == null) {
      final note = LicenseActions.lastActivationNote;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Pro plan activated.${note == null ? '' : ' $note'}'),
        ));
    }
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _trial() async {
    setState(() {
      _trialBusy = true;
      _error = null;
    });
    final err = await LicenseActions.claimTrial(ref);
    if (!mounted) return;
    setState(() {
      _trialBusy = false;
      _error = err;
    });
    if (err != null) ref.invalidate(trialOfferProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(licenseStatusProvider, (_, next) {
      // Small delay: activation may finish inside the Plans screen's
      // dialog, which must close before this route is replaced.
      if (next.activeNow) {
        Future.delayed(const Duration(milliseconds: 350), _continue);
      }
    });
    final trial = ref.watch(trialOfferProvider).valueOrNull;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy || _trialBusy,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 40, 20, 32),
            children: [
              Center(
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accentSoft,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.35),
                        blurRadius: 30,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.workspace_premium_rounded,
                      color: AppColors.accent, size: 38),
                ),
              ),
              const SizedBox(height: 26),
              const Text(
                'Activate MY IPTV',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Enter your licence key to continue, or pick a plan.',
                style: TextStyle(
                  color: Color(0xFF9A9A9F),
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 26),
              LicenseKeyField(controller: _key, onSubmitted: (_) => _activate()),
              if (_error != null) ...[
                const SizedBox(height: 14),
                LicenseErrorText(_error!),
              ],
              const SizedBox(height: 26),
              GlowButton(label: 'Activate', busy: _busy, onTap: _activate),
              const SizedBox(height: 22),
              if (trial != null)
                Center(
                  child: _trialBusy
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Color(0xFFFFD60A)),
                          ),
                        )
                      : TextButton.icon(
                          onPressed: _trial,
                          icon: const Icon(Icons.bolt_rounded,
                              color: Color(0xFFFFD60A)),
                          label: Text(
                            'Activate free plan (${trial.durationHours} hrs)',
                            style: const TextStyle(
                              color: Color(0xFFFFD60A),
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ),
              Center(
                child: TextButton.icon(
                  onPressed: () => context.push(Routes.plans),
                  icon: const Icon(Icons.sell_rounded, color: Colors.white),
                  label: const Text(
                    'See plans',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
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
