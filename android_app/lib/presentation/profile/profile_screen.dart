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

    // Real catalogue counts — the same providers Home already loads, so
    // this costs nothing extra once Home has been visited once.
    final movieCount = ref.watch(moviesProvider('')).valueOrNull?.length;
    final seriesCount = ref.watch(seriesProvider('')).valueOrNull?.length;
    final liveCount = ref.watch(liveChannelsProvider('')).valueOrNull?.length;

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Insets.lg,
          Insets.sm,
          Insets.lg,
          Insets.xxl * 3,
        ),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Profile', style: text.displaySmall),
                    const SizedBox(height: 2),
                    Text('Your playlist, account and preferences',
                        style: text.bodyMedium),
                  ],
                ),
              ),
              _HeaderIcon(
                icon: Icons.people_alt_rounded,
                tooltip: 'Accounts',
                onTap: () => context.push(Routes.accounts),
              ),
              const SizedBox(width: Insets.sm),
              _HeaderIcon(
                icon: Icons.settings_rounded,
                tooltip: 'Settings',
                onTap: () => context.push(Routes.settings),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),

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

          if (movieCount != null || seriesCount != null || liveCount != null) ...[
            const SizedBox(height: Insets.md),
            Container(
              padding: const EdgeInsets.all(Insets.lg),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(Radii.lg),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _StatTile(
                      value: movieCount,
                      label: 'Movies',
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: _StatTile(
                      value: seriesCount,
                      label: 'Series',
                      color: AppColors.tileBlue,
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: _StatTile(
                      value: liveCount,
                      label: 'Live TV',
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
            ),
          ],
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

          Text('Settings', style: text.headlineSmall),
          const SizedBox(height: Insets.xs),
          Text('Customize how the app fetches, plays and protects your content.',
              style: text.bodyMedium),
          const SizedBox(height: Insets.lg),

          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(
              children: [
                _SettingsRow(
                  icon: Icons.refresh_rounded,
                  color: AppColors.tileCyan,
                  title: 'Refresh Content',
                  subtitle: 'Pull the latest movies, series and channels.',
                  onTap: () async {
                    await ref.read(contentRepositoryProvider)?.invalidate();
                    ref.invalidate(liveChannelsProvider);
                    ref.invalidate(moviesProvider);
                    ref.invalidate(seriesProvider);
                    ref.invalidate(categoriesProvider);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Content refreshed')),
                      );
                    }
                  },
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 68),
                  child: Divider(height: 1),
                ),
                _SettingsRow(
                  icon: Icons.aspect_ratio_rounded,
                  color: AppColors.tileOrange,
                  title: 'Stream Format',
                  subtitle: 'Pick the container that plays best.',
                  onTap: () => context.push(Routes.settings),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 68),
                  child: Divider(height: 1),
                ),
                _SettingsRow(
                  icon: Icons.tune_rounded,
                  color: AppColors.tilePurple,
                  title: 'Advanced Settings',
                  subtitle: 'Default player, Home layout and refresh.',
                  onTap: () => context.push(Routes.settings),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 68),
                  child: Divider(height: 1),
                ),
                _SettingsRow(
                  icon: Icons.shield_outlined,
                  color: AppColors.success,
                  title: 'Security',
                  subtitle: 'Lock the app behind a passcode.',
                  onTap: () => context.push(Routes.security),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 68),
                  child: Divider(height: 1),
                ),
                _SettingsRow(
                  icon: Icons.power_settings_new_rounded,
                  color: AppColors.danger,
                  title: 'Logout',
                  subtitle: 'Sign out of this playlist on your device.',
                  titleColor: AppColors.danger,
                  onTap: () async {
                    await ref.read(authControllerProvider.notifier).signOut();
                    if (context.mounted) context.go(Routes.login);
                  },
                ),
              ],
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

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon(
      {required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        focusColor: AppColors.accentSoft,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// Movies/Series/Live TV counts, tinted per section like the reference.
/// Shows a dash while that catalogue hasn't loaded yet rather than a 0,
/// which would read as "empty" instead of "not fetched".
class _StatTile extends StatelessWidget {
  const _StatTile(
      {required this.value, required this.label, required this.color});

  final int? value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final formatted =
        value == null ? '—' : NumberFormat.decimalPattern().format(value);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm, vertical: Insets.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        children: [
          Text(
            formatted,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: color, fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      focusColor: AppColors.accentSoft,
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
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
                  Text(title,
                      style: text.titleMedium?.copyWith(color: titleColor)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textTertiary),
          ],
        ),
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
