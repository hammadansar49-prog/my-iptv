import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../providers.dart';
import 'pin_dialog.dart';

/// Profile → Security: a real 4-digit app-lock, not a decorative switch.
/// Turning it on asks for a PIN immediately (nothing is "on" with no PIN
/// set); turning it off asks for the current PIN first, so a device left
/// unlocked can't have the lock removed by whoever picks it up.
class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  Future<void> _enable(BuildContext context, WidgetRef ref) async {
    final pin = await showPinDialog(context, title: 'Set a PIN');
    if (pin == null || !context.mounted) return;
    final confirm =
        await showPinDialog(context, title: 'Confirm the PIN');
    if (confirm == null) return;
    if (pin != confirm) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('PINs did not match')));
      }
      return;
    }
    await ref.read(appLockProvider.notifier).setPin(pin);
  }

  Future<void> _disable(BuildContext context, WidgetRef ref) async {
    final pin = await showPinDialog(context, title: 'Enter current PIN');
    if (pin == null) return;
    final controller = ref.read(appLockProvider.notifier);
    if (!controller.verify(pin)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Wrong PIN')));
      }
      return;
    }
    await controller.disable();
  }

  Future<void> _change(BuildContext context, WidgetRef ref) async {
    final current = await showPinDialog(context, title: 'Enter current PIN');
    if (current == null) return;
    final controller = ref.read(appLockProvider.notifier);
    if (!controller.verify(current)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Wrong PIN')));
      }
      return;
    }
    if (!context.mounted) return;
    final next = await showPinDialog(context, title: 'New PIN');
    if (next == null) return;
    await controller.setPin(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pin = ref.watch(appLockProvider);
    final enabled = pin != null;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            Insets.lg, Insets.lg, Insets.lg, Insets.xxl),
        children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: SwitchListTile(
              value: enabled,
              onChanged: (v) =>
                  v ? _enable(context, ref) : _disable(context, ref),
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.accent,
              title: const Text('Lock app with a PIN'),
              subtitle: Text(
                enabled
                    ? 'A 4-digit PIN is asked for every time the app opens.'
                    : 'Off — anyone with the device can open the app.',
                style: text.bodySmall,
              ),
            ),
          ),
          if (enabled) ...[
            const SizedBox(height: Insets.lg),
            Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.lg),
                onTap: () => _change(context, ref),
                child: const Padding(
                  padding: EdgeInsets.all(Insets.lg),
                  child: Row(
                    children: [
                      Icon(Icons.password_rounded,
                          color: AppColors.textSecondary),
                      SizedBox(width: Insets.lg),
                      Expanded(child: Text('Change PIN')),
                      Icon(Icons.chevron_right_rounded,
                          color: AppColors.textTertiary),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
