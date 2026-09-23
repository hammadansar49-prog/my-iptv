import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/error_banner.dart';
import 'custom_models.dart';
import 'custom_store.dart';
import 'custom_widgets.dart';

/// Saved M3U playlists. Tap opens, long-press/menu renames or deletes.
class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(customPlaylistsProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
          onPressed: () => popOrSetup(context),
        ),
        title: const Text('M3U Playlists'),
      ),
      floatingActionButton: AddFab(
        tooltip: 'Add playlist',
        onTap: () => context.push(Routes.customPlaylistAdd),
      ),
      body: playlists.isEmpty
          ? EmptyState(
              icon: Icons.subscriptions_rounded,
              title: 'No Playlists Yet',
              message: 'Add an M3U playlist link to get started.',
              action: FilledButton(
                onPressed: () => context.push(Routes.customPlaylistAdd),
                child: const Text('Add playlist'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  Insets.lg, 0, Insets.lg, Insets.xxl * 3),
              itemCount: playlists.length,
              itemBuilder: (context, i) {
                final p = playlists[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.lg),
                      focusColor: AppColors.accentSoft,
                      onTap: () =>
                          context.push(Routes.customPlaylist, extra: p.id),
                      onLongPress: () => playlistMenu(context, ref, p),
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.lg),
                        child: Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(Radii.md),
                              ),
                              child: const Icon(Icons.subscriptions_rounded,
                                  color: Colors.white),
                            ),
                            const SizedBox(width: Insets.lg),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.titleLarge),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${p.entryCount} channels'
                                    '${p.lastRefresh == null ? '' : ' · updated ${_ago(p.lastRefresh!)}'}',
                                    style: text.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'More',
                              icon: const Icon(Icons.more_vert_rounded),
                              onPressed: () => playlistMenu(context, ref, p),
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

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Rename / delete. Shared by the list and the playlist screen's app bar.
/// Returns true when the playlist was deleted.
Future<bool> playlistMenu(
    BuildContext context, WidgetRef ref, M3uPlaylist p) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_rounded),
            title: const Text('Rename'),
            onTap: () => Navigator.of(context).pop('rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_rounded, color: AppColors.danger),
            title:
                const Text('Delete', style: TextStyle(color: AppColors.danger)),
            onTap: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return false;
  final notifier = ref.read(customPlaylistsProvider.notifier);
  if (action == 'rename') {
    final name = await _renameDialog(context, p.name);
    if (name != null && name.isNotEmpty) notifier.rename(p.id, name);
  } else if (action == 'delete' &&
      await confirmDelete(context, 'Delete playlist?',
          '"${p.name}" and its cached channel list will be removed.')) {
    await notifier.remove(p.id);
    return true;
  }
  return false;
}

Future<String?> _renameDialog(BuildContext context, String current) {
  // The controller is not disposed here on purpose: disposing it the moment
  // the Future completes races the dialog's exit animation, which still
  // rebuilds the TextField. It is tiny and garbage-collected with the route.
  final c = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surfaceHigh,
      title: const Text('Rename playlist'),
      content: TextField(
        controller: c,
        autofocus: true,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
