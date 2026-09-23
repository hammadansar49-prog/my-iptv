import 'package:flutter/material.dart';

import '../../core/storage/local_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../services/permissions/permission_service.dart';

/// LocalStore flag: the onboarding has been shown once (whatever the answer).
const _kOnboarded = 'notificationOnboardingShown';

/// First app open only: explain what notifications are for, then let the
/// user decide. The system prompt (Android 13+) appears only after "Allow".
/// Nothing asks for notifications automatically anywhere else.
Future<void> maybeShowNotificationOnboarding(
  BuildContext context,
  LocalStore store,
) async {
  if (store.read<bool>(_kOnboarded) == true) return;
  final status = await PermissionService.status(AppPermission.notifications);
  store.write(_kOnboarded, true);
  if (status == AppPermissionStatus.granted || !context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const NotificationOnboardingScreen(),
    ),
  );
}

class NotificationOnboardingScreen extends StatefulWidget {
  const NotificationOnboardingScreen({super.key});

  @override
  State<NotificationOnboardingScreen> createState() =>
      _NotificationOnboardingScreenState();
}

class _NotificationOnboardingScreenState
    extends State<NotificationOnboardingScreen> {
  bool _busy = false;

  Future<void> _allow() async {
    setState(() => _busy = true);
    await PermissionService.request(AppPermission.notifications);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Insets.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _BellArt(),
                  const SizedBox(height: Insets.xxl),
                  Text(
                    'Stay in the loop',
                    textAlign: TextAlign.center,
                    style: text.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: Insets.md),
                  Text(
                    'Turn on notifications so you never miss what matters.',
                    textAlign: TextAlign.center,
                    style: text.bodyLarge?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Insets.xl),
                  const _Reason(
                    icon: Icons.campaign_rounded,
                    color: AppColors.tilePurple,
                    title: 'Announcements',
                    body: 'New content, offers and important service news.',
                  ),
                  const SizedBox(height: Insets.md),
                  const _Reason(
                    icon: Icons.download_rounded,
                    color: AppColors.tileBlue,
                    title: 'Download progress',
                    body: 'See downloads finish even when the app is closed.',
                  ),
                  const SizedBox(height: Insets.xxl),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      autofocus: true,
                      onPressed: _busy ? null : _allow,
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Allow notifications'),
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                  const SizedBox(height: Insets.xs),
                  Text(
                    'You can change this any time in Profile > Notifications.',
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BellArt extends StatelessWidget {
  const _BellArt();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.85, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Container(
        width: 112,
        height: 112,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.accentSoft,
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
        ),
        child: const Icon(
          Icons.notifications_active_rounded,
          size: 54,
          color: AppColors.accent,
        ),
      ),
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Icon(icon, size: 20, color: Colors.white),
          ),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(body, style: text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Profile row subtitle source + tap action: re-ask while the system still
/// can, otherwise open the app's notification settings.
abstract final class NotificationSettingsAction {
  static String describe(AppPermissionStatus s) => switch (s) {
        AppPermissionStatus.granted => 'On — announcements and download progress.',
        AppPermissionStatus.denied => 'Off — tap to turn on.',
        AppPermissionStatus.permanentlyDenied =>
          'Off — tap to open notification settings.',
      };

  static Future<void> run() async {
    final s = await PermissionService.status(AppPermission.notifications);
    switch (s) {
      case AppPermissionStatus.granted:
      case AppPermissionStatus.permanentlyDenied:
        await PermissionService.openSettings(AppPermission.notifications);
      case AppPermissionStatus.denied:
        await PermissionService.request(AppPermission.notifications);
    }
  }
}
