import 'package:flutter/material.dart';
import '../app_state.dart';
import '../artwork.dart';
import '../downloads.dart';
import '../models.dart';
import '../theme.dart';

class DownloadsTab extends StatefulWidget {
  final AppState state;
  const DownloadsTab({super.key, required this.state});

  @override
  State<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends State<DownloadsTab> {
  @override
  void initState() {
    super.initState();
    widget.state.downloads.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.state.downloads.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() { if (mounted) setState(() {}); }

  void _play(DownloadItem d) {
    widget.state.launchPlayer(PlayRequest(
      url: d.filePath, isLive: false, type: d.type, title: d.title, subtitle: d.subtitle,
      thumb: d.thumb, historyKey: 'download:${d.id}', local: true,
    ));
  }

  Future<void> _confirmDelete(DownloadItem d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('Delete download?'),
        content: Text('"${d.title}${d.subtitle.isNotEmpty ? ' · ${d.subtitle}' : ''}" will be removed from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok == true) widget.state.downloads.remove(d.id);
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.state.downloads.items;
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: list.isEmpty ? _empty() : _list(list),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.download_for_offline_outlined, color: AppColors.textDim, size: 56),
              const SizedBox(height: 16),
              const Text('No content found!', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 6),
              const Text('Download now and come back to watch', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            ],
          ),
        ),
      );

  Widget _list(List<DownloadItem> list) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _row(list[i]),
    );
  }

  Widget _row(DownloadItem d) {
    final running = d.status == 'downloading' || d.status == 'queued' || d.status == 'waiting';
    return GestureDetector(
      onTap: d.status == 'completed' ? () => _play(d) : null,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: cardDecoration(radius: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Artwork(url: d.thumb, title: d.title, width: 56, radius: 8, placeholderIcon: Icons.movie_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (d.subtitle.isNotEmpty)
                    Text(d.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
                  const SizedBox(height: 6),
                  Text(downloadStatusText(d), style: TextStyle(
                    fontSize: 11,
                    color: d.status == 'failed' ? AppColors.danger : d.status == 'completed' ? AppColors.success : AppColors.textDim,
                  )),
                  if (d.status != 'completed') ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: d.progress, minHeight: 4, backgroundColor: AppColors.bg3,
                        color: running ? AppColors.accent : AppColors.textDim,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              children: [
                if (d.status == 'completed') ...[
                  IconButton(icon: const Icon(Icons.play_circle_fill, color: AppColors.accent), onPressed: () => _play(d)),
                ] else if (running) ...[
                  IconButton(icon: const Icon(Icons.pause_circle_outline, color: AppColors.textDim), onPressed: () => widget.state.downloads.pause(d.id)),
                ] else ...[
                  IconButton(
                    icon: Icon(d.status == 'failed' ? Icons.refresh : Icons.play_circle_outline, color: AppColors.accent),
                    onPressed: () => widget.state.downloads.resume(d.id),
                  ),
                ],
                IconButton(icon: const Icon(Icons.delete_outline, color: AppColors.textDim, size: 20), onPressed: () => _confirmDelete(d)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
