import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../providers.dart';
import '../widgets/network_artwork.dart';

/// Entry points plus Continue Watching. Progressive by design (spec §9): the
/// section tiles render instantly and each rail fills in on its own, so a
/// slow catalogue fetch never blocks the whole screen.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final continueWatching = ref.watch(continueWatchingProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            onPressed: () => context.push(Routes.favorites),
            icon: const Icon(Icons.favorite_border_rounded),
            tooltip: 'Favorites',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Insets.xxl * 3),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
            child: Row(
              children: [
                Expanded(
                  child: _SectionTile(
                    label: 'Live TV',
                    icon: Icons.live_tv_rounded,
                    color: AppColors.accent,
                    onTap: () => context.push(Routes.liveTv),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: _SectionTile(
                    label: 'Movies',
                    icon: Icons.movie_rounded,
                    color: AppColors.tileBlue,
                    onTap: () => context.push(Routes.movies),
                  ),
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: _SectionTile(
                    label: 'Series',
                    icon: Icons.video_library_rounded,
                    color: AppColors.tileGreen,
                    onTap: () => context.push(Routes.series),
                  ),
                ),
              ],
            ),
          ),

          if (continueWatching.isNotEmpty) ...[
            const SizedBox(height: Insets.xl),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              child: Text('Continue Watching', style: text.titleLarge),
            ),
            const SizedBox(height: Insets.md),
            SizedBox(
              height: 148,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
                itemCount: continueWatching.length,
                separatorBuilder: (_, __) => const SizedBox(width: Insets.md),
                itemBuilder: (context, i) {
                  final entry = continueWatching[i];
                  return SizedBox(
                    width: 200,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Stack(
                          children: [
                            NetworkArtwork(
                              url: entry.thumb,
                              width: 200,
                              height: 112,
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: entry.progress,
                                minHeight: 3,
                                backgroundColor: AppColors.divider,
                                valueColor: const AlwaysStoppedAnimation(
                                    AppColors.accent),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Insets.sm),
                        Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],

          const SizedBox(height: Insets.xl),
          _CatalogueSummary(),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.lg),
        focusColor: AppColors.accentSoft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.lg),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: Insets.sm),
              Text(label, style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ),
      ),
    );
  }
}

/// Counts straight from the cached catalogue, matching the three stat cards
/// in the design reference. Reads whatever is already loaded — it does not
/// trigger a fetch of its own.
class _CatalogueSummary extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movies = ref.watch(moviesProvider('')).valueOrNull?.length;
    final series = ref.watch(seriesProvider('')).valueOrNull?.length;
    final channels = ref.watch(liveChannelsProvider('')).valueOrNull?.length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Row(
        children: [
          Expanded(
            child: _Stat(
                value: movies, label: 'Movies', color: AppColors.accent),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: _Stat(
                value: series, label: 'Series', color: AppColors.tileBlue),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: _Stat(
                value: channels, label: 'Live TV', color: AppColors.tileGreen),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final int? value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Insets.lg),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Column(
        children: [
          Text(
            value == null ? '—' : _format(value!),
            style: TextStyle(
                color: color, fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  static String _format(int n) {
    final s = n.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
      buffer.write(s[i]);
    }
    return buffer.toString();
  }
}
