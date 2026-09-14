import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';

/// A 4-digit passcode gate shown when the app returns to the foreground
/// with a passcode set (see Profile → Settings → Security).
class LockScreen extends StatefulWidget {
  final AppState state;
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.state, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String entered = '';
  bool wrong = false;

  void _tap(String d) {
    if (entered.length >= 4) return;
    setState(() {
      entered += d;
      wrong = false;
    });
    if (entered.length == 4) {
      if (entered == widget.state.passcode) {
        widget.onUnlocked();
      } else {
        setState(() => wrong = true);
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) setState(() => entered = '');
        });
      }
    }
  }

  void _backspace() => setState(() => entered = entered.isEmpty ? '' : entered.substring(0, entered.length - 1));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: AppColors.accent, size: 40),
              const SizedBox(height: 14),
              const Text('Enter passcode', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(4, (i) {
                  final filled = i < entered.length;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: wrong ? AppColors.danger : (filled ? AppColors.accent : AppColors.bg3),
                      border: Border.all(color: wrong ? AppColors.danger : AppColors.border),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 34),
              SizedBox(
                width: 260,
                child: GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10, crossAxisSpacing: 10,
                  children: [
                    for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
                      _key(d, () => _tap(d)),
                    const SizedBox(),
                    _key('0', () => _tap('0')),
                    _key('⌫', _backspace, icon: Icons.backspace_outlined),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(String label, VoidCallback onTap, {IconData? icon}) {
    return Material(
      color: AppColors.bg2,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Center(
          child: icon != null
              ? Icon(icon, color: AppColors.textDim, size: 20)
              : Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
