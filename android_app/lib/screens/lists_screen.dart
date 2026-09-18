import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../artwork.dart';
import '../models.dart';
import '../theme.dart';
import 'series_screen.dart';
import 'live_tv_screen.dart';

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
            leading: Artwork(url: h.thumb, title: h.title, width: 60, radius: 6, placeholderIcon: Icons.movie_outlined),
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
              if (widget.state.client == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Session expired. Please log in again.')),
                );
                return;
              }
              final req = PlayRequest(
                url: h.url, isLive: h.isLive, type: h.type, title: h.title, subtitle: h.subtitle,
                thumb: h.thumb, historyKey: h.key, resumeAt: h.resumeAt,
              );
              widget.state.launchPlayer(req);
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
        return Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
              _openFavorite(f);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
          onTap: () => _openFavorite(f),
          child: Container(
            decoration: BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: Artwork(url: f.item.thumb, title: f.item.name, width: 150, fit: BoxFit.cover)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(f.item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  // Same fast-double-tap guard as HomeTab._openItem — a favorite card tapped
  // twice quickly used to stack two Navigator pushes (series/live) or race
  // two launchPlayer calls.
  DateTime? _lastOpenFavorite;

  void _openFavorite(FavoriteEntry f) {
    final now = DateTime.now();
    if (_lastOpenFavorite != null && now.difference(_lastOpenFavorite!) < const Duration(milliseconds: 800)) return;
    _lastOpenFavorite = now;
    if (f.section == 'series') {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SeriesScreen(state: widget.state, series: f.item)));
      return;
    }
    if (f.section == 'live') {
      final liveFavs = widget.state.favorites.where((x) => x.section == 'live').map((x) => x.item).toList();
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveTvScreen(state: widget.state, channels: liveFavs, initial: f.item)));
      return;
    }
    final client = widget.state.client;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Session expired. Please login again.')));
      return;
    }
    final req = PlayRequest(
      url: client.vodUrl(f.item.id, ext: f.item.containerExt ?? 'mp4'), isLive: false, type: 'movie',
      title: f.item.name, subtitle: 'Movie', thumb: f.item.thumb, historyKey: 'movie:${f.item.id}',
    );
    final existing = widget.state.findHistory(req.historyKey);
    if (existing != null) req.resumeAt = existing.resumeAt;
    widget.state.launchPlayer(req, favSection: f.section, favItem: f.item);
  }
}
