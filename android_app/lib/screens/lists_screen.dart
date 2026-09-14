import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'player_screen.dart';
import 'series_screen.dart';

enum ListsKind { continueWatching, recent, favorites }

class ListsScreen extends StatefulWidget {
  final AppState state;
  final ListsKind kind;
  const ListsScreen({super.key, required this.state, required this.kind});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  String get _title {
    switch (widget.kind) {
      case ListsKind.continueWatching:
        return 'Continue Watching';
      case ListsKind.recent:
        return 'Recently Watched';
      case ListsKind.favorites:
        return 'Favorites';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: widget.kind == ListsKind.favorites ? _buildFavorites() : _buildHistory(),
    );
  }

  Widget _buildHistory() {
    final list = widget.kind == ListsKind.continueWatching
        ? widget.state.continueWatching
        : widget.state.history;
    if (list.isEmpty) {
      return Center(
        child: Text(
          widget.kind == ListsKind.continueWatching ? 'Nothing in progress yet.' : 'Nothing watched yet.',
          style: const TextStyle(color: AppColors.textDim),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final h = list[i];
        return Card(
          color: AppColors.bg2,
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 60, height: 60,
                child: h.thumb.isNotEmpty
                    ? Image.network(h.thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppColors.bg3))
                    : Container(color: AppColors.bg3),
              ),
            ),
            title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(h.subtitle, style: const TextStyle(fontSize: 11, color: AppColors.textDim), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (h.duration > 0) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: h.progressPct, minHeight: 3, backgroundColor: AppColors.bg3, color: AppColors.accent),
                  ),
                ],
              ],
            ),
            onTap: () {
              final req = PlayRequest(
                url: h.url, isLive: h.isLive, type: h.type, title: h.title, subtitle: h.subtitle,
                thumb: h.thumb, historyKey: h.key, resumeAt: h.resumeAt,
              );
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(state: widget.state, request: req)));
            },
          ),
        );
      },
    );
  }

  Widget _buildFavorites() {
    final list = widget.state.favorites;
    if (list.isEmpty) {
      return const Center(child: Text('No favorites yet — tap the heart on any item.', style: TextStyle(color: AppColors.textDim)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150, childAspectRatio: 2 / 3.4, crossAxisSpacing: 10, mainAxisSpacing: 10,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final f = list[i];
        return GestureDetector(
          onTap: () => _openFavorite(f),
          child: Container(
            decoration: BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: f.item.thumb.isNotEmpty
                      ? Image.network(f.item.thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppColors.bg3))
                      : Container(color: AppColors.bg3, alignment: Alignment.center, child: Text(f.item.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11))),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(f.item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openFavorite(FavoriteEntry f) {
    if (f.section == 'series') {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(state: widget.state, series: f.item)));
      return;
    }
    final client = widget.state.client!;
    final req = f.section == 'live'
        ? PlayRequest(
            url: client.liveUrl(f.item.id, ext: 'm3u8'), isLive: true, type: 'live',
            title: f.item.name, subtitle: 'Live TV', thumb: f.item.thumb, historyKey: 'live:${f.item.id}',
          )
        : PlayRequest(
            url: client.vodUrl(f.item.id, ext: f.item.containerExt), isLive: false, type: 'movie',
            title: f.item.name, subtitle: 'Movie', thumb: f.item.thumb, historyKey: 'movie:${f.item.id}',
          );
    final existing = widget.state.findHistory(req.historyKey);
    if (existing != null) req.resumeAt = existing.resumeAt;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(state: widget.state, request: req, favSection: f.section, favItem: f.item),
    ));
  }
}
