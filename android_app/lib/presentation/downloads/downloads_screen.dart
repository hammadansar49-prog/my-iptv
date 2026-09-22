import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../providers.dart';
import '../widgets/error_banner.dart';

/// Phase 7 adds the grouped Downloading/Paused/Completed/Failed sections and
/// the per-item controls. The list itself is already live — the download
/// manager is wired from Phase 2.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(downloadListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.only(bottom: Insets.xxl),
              child: EmptyState(
                icon: Icons.download_outlined,
                title: 'No downloads yet',
                message: 'No content found! Download now and come back to watch.',
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.sm,
                Insets.lg,
                Insets.xxl * 3,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(item.title),
                  subtitle: Text(
                    '${item.status.name} — ${(item.progress * 100).toStringAsFixed(0)}%',
                  ),
                );
              },
            ),
    );
  }
}
