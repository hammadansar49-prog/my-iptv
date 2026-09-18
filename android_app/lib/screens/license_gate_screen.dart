import 'dart:async';
import 'package:flutter/material.dart';
import '../license.dart';
import '../license_key_formatter.dart';
import '../theme.dart';

/// Blocks the app the same way `view-license` blocks `boot()` on PC: nothing
/// past this screen until a valid, unexpired key (or an active trial) is on
/// this device. "See Plans" -> pick a plan -> WhatsApp opens with a
/// prefilled message naming the plan — the actual purchase is still a manual
/// handoff to the admin, same as on PC; there's no in-app checkout yet.
class LicenseGateScreen extends StatefulWidget {
  final LicenseService license;
  final VoidCallback onUnlocked;
  const LicenseGateScreen({super.key, required this.license, required this.onUnlocked});

  @override
  State<LicenseGateScreen> createState() => _LicenseGateScreenState();
}

class _LicenseGateScreenState extends State<LicenseGateScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showPlans = false;
  List<LicensePlan> _plans = [];
  bool _plansLoading = false;
  Map<String, dynamic>? _trialAvailability;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final result = await widget.license.verifyKey(key).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() => _busy = false);
      if (result['valid'] == true) {
        widget.onUnlocked();
        return;
      }
      setState(() => _error = _reasonText(result['reason'] as String?));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't reach the license server. Check your connection and try again.";
      });
    }
  }

  String _reasonText(String? reason) {
    switch (reason) {
      case 'not-found': return 'That key was not found. Check it and try again.';
      case 'revoked': return 'This key has been revoked.';
      case 'expired': return 'This key has expired.';
      case 'device-limit-reached': return 'This key is already active on the maximum number of devices.';
      case 'network-error': return "Couldn't reach the license server. Check your connection and try again.";
      default: return 'That key could not be activated.';
    }
  }

  Future<void> _openPlans() async {
    setState(() { _showPlans = true; _plansLoading = true; });
    try {
      final results = await Future.wait([
        widget.license.getPlans(),
        widget.license.checkTrialAvailability(),
      ]);
      if (!mounted) return;
      setState(() {
        _plans = results[0] as List<LicensePlan>;
        _trialAvailability = results[1] as Map<String, dynamic>;
        _plansLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _plansLoading = false; });
    }
  }

  Future<void> _getPackage(LicensePlan plan) async {
    final ok = await widget.license.openPlanOnWhatsApp(plan);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open WhatsApp. Please try again in a moment.")),
      );
    }
  }

  Future<void> _claimTrial() async {
    setState(() => _busy = true);
    final result = await widget.license.claimTrial();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result['ok'] == true) {
      widget.onUnlocked();
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result['reason'] == 'already-claimed'
          ? 'This device has already used its free trial.'
          : "Couldn't start the trial. Please try again.")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: _showPlans ? _buildPlans() : _buildKeyEntry(),
      ),
    );
  }

  Widget _buildKeyEntry() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.live_tv, color: AppColors.accent, size: 56),
            const SizedBox(height: 12),
            const Text('MY IPTV', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Enter your license key to continue', style: TextStyle(color: AppColors.textDim, fontSize: 13)),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              textAlign: TextAlign.center,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [LicenseKeyFormatter()],
              style: const TextStyle(letterSpacing: 1.5, fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w600),
              decoration: const InputDecoration(hintText: 'MYIPTV-XXXXXX-XXXXXX-XXXXXX'),
              onSubmitted: (_) => _verify(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _verify,
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Unlock'),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: _busy ? null : _openPlans, child: const Text('See Plans')),
          ],
        ),
      ),
    );
  }

  Widget _buildPlans() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _showPlans = false)),
              const Text('Plans', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Expanded(
          child: _plansLoading
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    if (_trialAvailability?['available'] == true) _buildTrialCard(),
                    ..._plans.map(_buildPlanCard),
                    if (_plans.isEmpty && _trialAvailability?['available'] != true)
                      const Padding(
                        padding: EdgeInsets.only(top: 40),
                        child: Text('No plans are available right now — please check back later.',
                            textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim)),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildTrialCard() {
    final config = _trialAvailability?['config'] as Map<String, dynamic>?;
    final hours = config?['durationHours'] as int? ?? 24;
    final specs = (config?['specs'] as String?) ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(color: AppColors.bg2).copyWith(border: Border.all(color: AppColors.accent)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Free Trial · $hours ${hours == 1 ? 'hour' : 'hours'}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          if (specs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(specs, style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: _busy ? null : _claimTrial, child: const Text('Get Free Trial')),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanCard(LicensePlan plan) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(plan.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Text('${plan.formattedPrice} / ${plan.periodLabel}',
                  style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          if (plan.specs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(plan.specs, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: () => _getPackage(plan), child: const Text('Get Package')),
          ),
        ],
      ),
    );
  }
}
