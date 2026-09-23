import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/logger.dart';
import '../providers.dart';
import 'auth_controller.dart';

/// Spec §8: initialise, check the session, prepare services, then navigate.
/// Never an infinite spinner — a hard timeout forces a decision.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _tag = 'Splash';

  /// Absolute ceiling on startup. If anything hangs past this we go to the
  /// login screen rather than leaving the user staring at a logo.
  static const _deadline = Duration(seconds: 12);

  late final AnimationController _fade;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    unawaited(_start());
  }

  Future<void> _start() async {
    final stopwatch = Stopwatch()..start();
    var target = Routes.login;

    try {
      await Future.any([
        _initialise().then((restored) {
          target = restored ? Routes.home : Routes.login;
        }),
        Future<void>.delayed(_deadline).then((_) {
          Log.w(_tag, 'startup hit the ${_deadline.inSeconds}s deadline');
        }),
      ]);
    } catch (e, st) {
      Log.e(_tag, 'startup failed', e, st);
    }

    // Let the logo breathe for a beat so the app does not flash past.
    final elapsed = stopwatch.elapsed;
    const minimum = Duration(milliseconds: 900);
    if (elapsed < minimum) {
      await Future<void>.delayed(minimum - elapsed);
    }

    if (!mounted || _navigated) return;
    _navigated = true;

    // App-lock (Profile → Security) gates every target, not just Home — a
    // PIN protects the device even if the session already expired to the
    // login screen.
    if (ref.read(appLockProvider) != null) {
      context.go(Routes.lock, extra: target);
      return;
    }
    context.go(target);
  }

  Future<bool> _initialise() async {
    // Downloads resume on their own timer once initialised.
    await ref.read(downloadManagerProvider).init();

    // Cached license first: it is a local read and decides nothing on its
    // own here, but having it loaded means the profile screen is instant.
    await ref.read(licenseRepositoryProvider).load();

    await ref.read(appLockProvider.notifier).load();

    return ref.read(authControllerProvider.notifier).restore();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemOverlay,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: FadeTransition(
            opacity: _fade,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 52,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: Insets.xl),
                Text(
                  'TheOttDeals',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: Insets.xxl),
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
