import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';
import 'custom_models.dart';
import 'custom_store.dart';
import 'custom_widgets.dart';

/// "My Channels": the saved Single Channels. Tap plays, long-press or the
/// menu edits/deletes.
class MyChannelsScreen extends ConsumerWidget {
  const MyChannelsScreen({super.key});

  Future<void> _menu(
      BuildContext context, WidgetRef ref, CustomChannel ch) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Edit'),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_rounded, color: AppColors.danger),
              title: const Text('Delete',
                  style: TextStyle(color: AppColors.danger)),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'edit') {
      context.push(Routes.customChannelEdit, extra: ch);
    } else if (action == 'delete' &&
        await confirmDelete(
            context, 'Delete channel?', '"${ch.name}" will be removed.')) {
      ref.read(customChannelsProvider.notifier).remove(ch.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(customChannelsProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
          onPressed: () => popOrSetup(context),
        ),
        title: const Text('My Channels'),
      ),
      floatingActionButton: AddFab(
        tooltip: 'Add channel',
        onTap: () => context.push(Routes.customChannelEdit),
      ),
      body: channels.isEmpty
          ? EmptyState(
              icon: Icons.podcasts_rounded,
              title: 'No Channels Yet',
              message: 'Add a channel with its streaming link.',
              action: FilledButton(
                onPressed: () => context.push(Routes.customChannelEdit),
                child: const Text('Add channel'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  Insets.lg, 0, Insets.lg, Insets.xxl * 3),
              itemCount: channels.length,
              itemBuilder: (context, i) {
                final ch = channels[i];
                final live = isLiveUrl(ch.url);
                return Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.lg),
                      focusColor: AppColors.accentSoft,
                      onTap: () => playCustom(
                        context,
                        ref,
                        url: ch.url,
                        title: ch.name,
                        thumb: ch.logo,
                        historyKey: 'custom:${ch.id}',
                        returnTo: Routes.customChannels,
                      ),
                      onLongPress: () => _menu(context, ref, ch),
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.md),
                        child: Row(
                          children: [
                            NetworkArtwork(
                              url: ch.logo,
                              width: 56,
                              height: 56,
                              fit: BoxFit.contain,
                              fallbackIcon: Icons.podcasts_rounded,
                              fallbackLabel: ch.name,
                            ),
                            const SizedBox(width: Insets.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(ch.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.titleMedium),
                                  const SizedBox(height: 2),
                                  Text(ch.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.bodySmall),
                                ],
                              ),
                            ),
                            if (live)
                              const Padding(
                                padding: EdgeInsets.only(left: Insets.sm),
                                child: Text('LIVE',
                                    style: TextStyle(
                                        color: AppColors.accent,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.8)),
                              ),
                            IconButton(
                              tooltip: 'More',
                              icon: const Icon(Icons.more_vert_rounded),
                              onPressed: () => _menu(context, ref, ch),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
