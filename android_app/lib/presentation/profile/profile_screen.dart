import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../providers.dart';

/// Account summary modelled on the design screenshot: avatar + status pill,
/// then a grid of subscription facts. Every value comes from the panel's real
/// `user_info` — spec §33/§34 forbid invented states.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final session = ref.watch(sessionProvider);
    final user = session?.userInfo;
    final text = Theme.of(context).textTheme;
    final dateFmt = DateFormat('EEE, MMM d, y');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            onPressed: () => context.push(Routes.settings),
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Insets.lg,
          0,
          Insets.lg,
          Insets.xxl * 3,
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppColors.accent,
                  child: Text(
                    (auth.account?.name.isNotEmpty ?? false)
                        ? auth.account!.name[0].toUpperCase()
                        : '?',
                    style: text.headlineSmall?.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(width: Insets.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.account?.name ?? 'Not signed in',
                        style: text.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(user?.username ?? '', style: text.bodySmall),
                    ],
                  ),
                ),
                if (user != null) _StatusPill(status: user.status),
              ],
            ),
          ),
          const SizedBox(height: Insets.xl),

          if (user != null) ...[
            Text('Account', style: text.headlineSmall),
            const SizedBox(height: Insets.xs),
            Text('Your subscription at a glance.', style: text.bodyMedium),
            const SizedBox(height: Insets.lg),
            Row(
              children: [
                Expanded(
                  child: _FactTile(
                    icon: Icons.calendar_today_rounded,
                    iconColor: AppColors.tileBlue,
                    label: 'Expires',
                    value: user.expiresAt == null
                        ? 'Never'
                        : dateFmt.format(user.expiresAt!),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: _FactTile(
                    icon: Icons.timer_outlined,
                    iconColor: AppColors.accent,
                    label: 'Trial',
                    value: user.isTrial ? 'Yes' : 'No',
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.md),
            Row(
              children: [
                Expanded(
                  child: _FactTile(
                    icon: Icons.podcasts_rounded,
                    iconColor: AppColors.success,
                    label: 'Connections',
                    value: '${user.activeConnections} / ${user.maxConnections}',
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: _FactTile(
                    icon: Icons.person_outline_rounded,
                    iconColor: AppColors.tilePurple,
                    label: 'Member since',
                    value: user.createdAt == null
                        ? '—'
                        : dateFmt.format(user.createdAt!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.xl),
          ],

          Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(Radii.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.lg),
              onTap: () async {
                await ref.read(authControllerProvider.notifier).signOut();
                if (context.mounted) context.go(Routes.login);
              },
              child: Padding(
                padding: const EdgeInsets.all(Insets.lg),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.danger,
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                      child: const Icon(Icons.power_settings_new_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: Insets.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Logout',
                            style: text.titleMedium
                                ?.copyWith(color: AppColors.danger),
                          ),
                          Text('Sign out of this playlist on your device.',
                              style: text.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final active = status.toLowerCase() == 'active';
    final color = active ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.md, vertical: Insets.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            status,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _FactTile extends StatelessWidget {
  const _FactTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(label, style: text.bodyMedium, maxLines: 1),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            value,
            style: text.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
