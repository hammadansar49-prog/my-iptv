import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../../services/player/playback_request.dart';
import '../providers.dart';
import '../widgets/network_artwork.dart';
import 'empty_downloads_art.dart';

/// Downloads grouped into Downloading / Paused / Completed / Failed
/// (spec §27), each row showing progress, size, speed and its controls.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(downloadListProvider);

    if (items.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('Downloads')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: Insets.xxl * 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const EmptyDownloadsArt(),
                const SizedBox(height: Insets.xl),
                Text(
                  'No content found! Download now\nand come back to watch',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: AppColors.textSecondary, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      );
    }

    List<DownloadItem> of(Set<DownloadStatus> statuses) =>
        items.where((i) => statuses.contains(i.status)).toList();

    final downloading = of({
      DownloadStatus.downloading,
      DownloadStatus.queued,
      DownloadStatus.waiting,
    });
    final paused = of({DownloadStatus.paused});
    final completed = of({DownloadStatus.completed});
    final failed = of({DownloadStatus.failed});

    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            Insets.lg, 0, Insets.lg, Insets.xxl * 3),
        children: [
          if (downloading.isNotEmpty)
            _Group(title: 'Downloading', items: downloading),
          if (paused.isNotEmpty) _Group(title: 'Paused', items: paused),
          if (completed.isNotEmpty) _Group(title: 'Completed', items: completed),
          if (failed.isNotEmpty) _Group(title: 'Failed', items: failed),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.items});

  final String title;
  final List<DownloadItem> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: Insets.lg),
        Text(
          '$title (${items.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: Insets.md),
        ...items.map((i) => _DownloadRow(item: i)),
      ],
    );
  }
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.item});

  final DownloadItem item;

  static String _bytes(int b) {
    if (b <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = b.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String _eta(Duration? d) {
    if (d == null) return '';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m left';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s left';
    return '${d.inSeconds}s left';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final manager = ref.read(downloadManagerProvider);
    final speed = manager.speedOf(item.id);
    final eta = manager.etaOf(item);
    final isComplete = item.status == DownloadStatus.completed;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          focusColor: AppColors.accentSoft,
          onTap: isComplete
              ? () => context.push(
                    Routes.player,
                    extra: PlaybackRequest(
                      // A completed download plays from disk; the remote
                      // stream is never requested again (spec §29).
                      url: item.url,
                      localFile: item.filePath,
                      title: item.title,
                      subtitle: item.subtitle,
                      thumb: item.thumb,
                      isLive: false,
                      historyKey: 'download:${item.id}',
                      section: item.isEpisode
                          ? ContentSection.series
                          : ContentSection.movies,
                    ),
                  )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NetworkArtwork(
                  url: item.thumb,
                  width: 64,
                  height: 92,
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyLarge,
                      ),
                      if (item.subtitle.isNotEmpty)
                        Text(
                          item.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      const SizedBox(height: Insets.sm),

                      if (!isComplete) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: item.totalBytes > 0 ? item.progress : null,
                            minHeight: 4,
                            backgroundColor: AppColors.divider,
                            valueColor: AlwaysStoppedAnimation(
                              item.status == DownloadStatus.failed
                                  ? AppColors.danger
                                  : AppColors.accent,
                            ),
                          ),
                        ),
                        const SizedBox(height: Insets.xs),
                      ],

                      Text(
                        switch (item.status) {
                          DownloadStatus.completed => _bytes(item.totalBytes),
                          DownloadStatus.failed =>
                            item.error.isEmpty ? 'Failed' : item.error,
                          DownloadStatus.waiting =>
                            'Waiting — something is playing',
                          DownloadStatus.queued => 'Queued',
                          DownloadStatus.paused =>
                            '${_bytes(item.receivedBytes)} of ${_bytes(item.totalBytes)} · Paused',
                          DownloadStatus.downloading =>
                            '${_bytes(item.receivedBytes)} of ${_bytes(item.totalBytes)}'
                                '${speed > 0 ? ' · ${_bytes(speed.round())}/s' : ''}'
                                '${eta != null ? ' · ${_eta(eta)}' : ''}',
                        },
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: item.status == DownloadStatus.failed
                              ? AppColors.danger
                              : AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),

                Column(
                  children: [
                    if (item.status == DownloadStatus.downloading ||
                        item.status == DownloadStatus.queued ||
                        item.status == DownloadStatus.waiting)
                      IconButton(
                        tooltip: 'Pause',
                        onPressed: () => manager.pause(item.id),
                        icon: const Icon(Icons.pause_rounded, size: 20),
                        color: AppColors.textSecondary,
                      )
                    else if (item.status == DownloadStatus.paused ||
                        item.status == DownloadStatus.failed)
                      IconButton(
                        tooltip: item.status == DownloadStatus.failed
                            ? 'Retry'
                            : 'Resume',
                        onPressed: () => manager.resume(item.id),
                        icon: Icon(
                          item.status == DownloadStatus.failed
                              ? Icons.refresh_rounded
                              : Icons.play_arrow_rounded,
                          size: 20,
                        ),
                        color: AppColors.textSecondary,
                      )
                    else
                      const Icon(Icons.play_circle_outline_rounded,
                          size: 20, color: AppColors.success),
                    IconButton(
                      tooltip: 'Delete',
                      onPressed: () => _confirmDelete(context, ref),
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      color: AppColors.textTertiary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Delete download?'),
        content: Text('"${item.title}" will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(downloadManagerProvider).remove(item.id);
    }
  }
}
