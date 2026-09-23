import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../providers.dart';

/// Shown at startup instead of [Routes.home] whenever a PIN is set (Profile
/// → Security). `extra` is the route the splash was about to go to; a
/// correct PIN continues there with `context.go` (replacing this screen,
/// not stacking on top of it — back should not return to the lock).
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key, required this.target});

  final String target;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (value.length != 4) return;
    final ok = ref.read(appLockProvider.notifier).verify(value);
    if (ok) {
      context.go(widget.target);
      return;
    }
    setState(() => _error = 'Wrong PIN');
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_rounded,
                      color: Colors.white, size: 34),
                ),
                const SizedBox(height: Insets.xl),
                Text('Enter your PIN',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: Insets.xl),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    style: const TextStyle(fontSize: 26, letterSpacing: 10),
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(counterText: ''),
                    onChanged: (v) {
                      if (_error != null) setState(() => _error = null);
                      if (v.length == 4) _submit(v);
                    },
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: Insets.md),
                  Text(_error!,
                      style: const TextStyle(color: AppColors.danger)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
