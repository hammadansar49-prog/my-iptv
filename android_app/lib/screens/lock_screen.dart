import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
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
  int _failCount = 0;
  Timer? _lockoutTimer;
  int _lockoutSeconds = 0;

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    super.dispose();
  }

  /// Escalating lockout: 3 fails → 10s, 5 fails → 30s, 7 fails → 60s.
  int get _lockoutDuration {
    if (_failCount >= 7) return 60;
    if (_failCount >= 5) return 30;
    if (_failCount >= 3) return 10;
    return 0;
  }

  void _startLockout() {
    _lockoutSeconds = _lockoutDuration;
    if (_lockoutSeconds <= 0) return;
    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_lockoutSeconds <= 0) {
        t.cancel();
        setState(() => _lockoutSeconds = 0);
      } else {
        setState(() => _lockoutSeconds--);
      }
    });
  }

  void _tap(String d) {
    if (entered.length >= 4) return;
    if (_lockoutSeconds > 0) return;
    setState(() {
      entered += d;
      wrong = false;
    });
    if (entered.length == 4) {
      final hashedEntered = sha256.convert(utf8.encode(entered)).toString();
      if (hashedEntered == widget.state.passcode) {
        _failCount = 0;
        _lockoutTimer?.cancel();
        widget.onUnlocked();
      } else {
        _failCount++;
        setState(() => wrong = true);
        _startLockout();
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) setState(() { entered = ''; wrong = false; });
        });
      }
    }
  }

  void _backspace() {
    if (_lockoutSeconds > 0) return;
    setState(() => entered = entered.isEmpty ? '' : entered.substring(0, entered.length - 1));
  }

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
              Text(
                _lockoutSeconds > 0 ? 'Too many attempts. Wait $_lockoutSeconds s' : 'Enter passcode',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
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
