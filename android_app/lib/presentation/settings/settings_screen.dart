import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../providers.dart';
import 'settings_controller.dart';

/// Grouped settings rows with coloured icon tiles, matching the design
/// reference. Scope follows spec §35 — playback, application, about.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final guard = ref.watch(connectionGuardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            Insets.lg, 0, Insets.lg, Insets.xxl * 2),
        children: [
          const _SectionLabel('PLAYBACK'),
          _Group(children: [
            _SwitchRow(
              icon: Icons.skip_next_rounded,
              color: AppColors.tilePurple,
              title: 'Autoplay next episode',
              subtitle: 'Start the next episode when one finishes.',
              value: settings.autoPlayNextEpisode,
              onChanged: controller.setAutoPlayNextEpisode,
            ),
            _ChoiceRow(
              icon: Icons.aspect_ratio_rounded,
              color: AppColors.tileOrange,
              title: 'Stream format',
              subtitle: 'Pick the container that plays best.',
              value: settings.preferredLiveExtension,
              options: const ['m3u8', 'ts'],
              onChanged: controller.setPreferredLiveExtension,
            ),
          ]),

          const _SectionLabel('DOWNLOADS'),
          _Group(children: [
            _SwitchRow(
              icon: Icons.download_rounded,
              color: AppColors.tileCyan,
              title: 'Download while watching',
              // The honest explanation: this is meaningless on a
              // one-connection account, and the UI says so rather than
              // pretending the toggle did something.
              subtitle: guard.maxConnections > 1
                  ? 'Keep downloading while something is playing.'
                  : 'Your account allows one connection, so downloads always '
                      'pause while something plays.',
              value: settings.downloadWhileWatching,
              enabled: guard.maxConnections > 1,
              onChanged: controller.setDownloadWhileWatching,
            ),
          ]),

          const _SectionLabel('CONTENT'),
          _Group(children: [
            _TapRow(
              icon: Icons.refresh_rounded,
              color: AppColors.tileCyan,
              title: 'Refresh content',
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
            _TapRow(
              icon: Icons.history_rounded,
              color: AppColors.tileYellow,
              title: 'Clear watch history',
              subtitle: 'Removes Continue Watching and Recently Watched.',
              onTap: () async {
                await ref.read(libraryRepositoryProvider).clearHistory();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('History cleared')),
                  );
                }
              },
            ),
          ]),

          const _SectionLabel('ABOUT'),
          _Group(children: [
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => _TapRow(
                icon: Icons.info_outline_rounded,
                color: AppColors.tileBlue,
                title: 'MY IPTV',
                subtitle: snap.hasData
                    ? 'Version ${snap.data!.version} (${snap.data!.buildNumber})'
                    : 'Version —',
                onTap: null,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.xl, 0, Insets.md),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
      );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.only(left: 68),
                child: Divider(height: 1),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Row(
          children: [
            _IconTile(icon: icon, color: color),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: enabled ? onChanged : null,
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _TapRow extends StatelessWidget {
  const _TapRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

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
            _IconTile(icon: icon, color: color),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(Insets.lg),
      child: Row(
        children: [
          _IconTile(icon: icon, color: color),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: text.bodySmall),
              ],
            ),
          ),
          DropdownButton<String>(
            value: value,
            underline: const SizedBox.shrink(),
            dropdownColor: AppColors.surfaceHigh,
            items: [
              for (final o in options)
                DropdownMenuItem(value: o, child: Text('.$o')),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
