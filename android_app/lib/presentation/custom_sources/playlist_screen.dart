import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/errors/app_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/error_banner.dart';
import '../widgets/network_artwork.dart';
import 'custom_models.dart';
import 'custom_store.dart';
import 'custom_widgets.dart';
import 'playlists_screen.dart';

/// One M3U playlist: group chips, search, lazy list, pull-to-refresh.
///
/// Built for 20k+ entries: parsing happens in a background isolate, both
/// lists are `builder`s (only visible rows exist), rows have a fixed
/// extent so scrolling never measures, and the filter is a single pass over
/// pre-lowercased names.
class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  static const _rowExtent = 72.0;

  final _search = TextEditingController();
  List<M3uEntry> _all = const [];
  List<String> _groups = const [];
  List<M3uEntry> _visible = const [];
  String? _group; // null = All
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notifier = ref.read(customPlaylistsProvider.notifier);
    try {
      final cached = await notifier.loadCached(widget.playlistId);
      if (cached != null) {
        _setEntries(cached);
      } else {
        // No cache on disk (cleared storage): fetch again.
        _setEntries(await notifier.refresh(widget.playlistId));
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load this playlist.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    try {
      final entries = await ref
          .read(customPlaylistsProvider.notifier)
          .refresh(widget.playlistId);
      _setEntries(entries);
      if (mounted) setState(() => _error = null);
    } on AppError catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Could not refresh this playlist.');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _setEntries(List<M3uEntry> entries) {
    if (!mounted) return;
    final seen = <String>{};
    final groups = <String>[];
    for (final e in entries) {
      final g = e.group;
      if (g != null && seen.add(g)) groups.add(g);
    }
    _all = entries;
    _groups = groups;
    if (_group != null && !seen.contains(_group)) _group = null;
    _applyFilter();
  }

  void _applyFilter() {
    final q = _search.text.trim().toLowerCase();
    final g = _group;
    setState(() {
      _visible = (q.isEmpty && g == null)
          ? _all
          : _all
              .where((e) =>
                  (g == null || e.group == g) &&
                  (q.isEmpty || e.searchKey.contains(q)))
              .toList(growable: false);
    });
  }

  void _play(M3uEntry e, M3uPlaylist p) => playCustom(
        context,
        ref,
        url: e.url,
        title: e.name,
        subtitle: e.group ?? p.name,
        thumb: e.logo,
        // Keyed by URL (not index) so it stays stable across refreshes.
        historyKey: 'custom:m3u:${p.id}:${e.url.hashCode.toRadixString(36)}',
        returnTo: Routes.customPlaylists,
      );

  @override
  Widget build(BuildContext context) {
    final playlist = ref.watch(customPlaylistsProvider
        .select((l) => l.where((p) => p.id == widget.playlistId).firstOrNull));

    if (playlist == null) {
      // Deleted (or a stale id).
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.subscriptions_rounded,
          title: 'Playlist not found',
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 30),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go(Routes.customPlaylists),
        ),
        title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: () async {
              final deleted = await playlistMenu(context, ref, playlist);
              if (deleted && context.mounted) popOrSetup(context);
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _all.isEmpty
              ? EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load playlist',
                  message: _error,
                  action: FilledButton(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = null;
                      });
                      _refresh().whenComplete(() {
                        if (mounted) setState(() => _loading = false);
                      });
                    },
                    child: const Text('Try again'),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          Insets.lg, 0, Insets.lg, Insets.sm),
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => _applyFilter(),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search ${_all.length} channels',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () {
                                    _search.clear();
                                    _applyFilter();
                                  },
                                ),
                        ),
                      ),
                    ),
                    if (_groups.isNotEmpty)
                      SizedBox(
                        height: 44,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding:
                              const EdgeInsets.symmetric(horizontal: Insets.lg),
                          itemCount: _groups.length + 1,
                          itemBuilder: (context, i) {
                            final g = i == 0 ? null : _groups[i - 1];
                            return Padding(
                              padding: const EdgeInsets.only(right: Insets.sm),
                              child: _GroupChip(
                                label: g ?? 'All',
                                selected: _group == g,
                                onTap: () {
                                  _group = g;
                                  _applyFilter();
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: Insets.sm),
                    Expanded(
                      child: RefreshIndicator(
                        color: AppColors.accent,
                        onRefresh: _refresh,
                        child: _visible.isEmpty
                            ? ListView(
                                // Scrollable so pull-to-refresh still works.
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 80),
                                  EmptyState(
                                    icon: Icons.search_off_rounded,
                                    title: 'No channels match',
                                  ),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                    Insets.lg, 0, Insets.lg, Insets.xxl),
                                itemExtent: _rowExtent,
                                itemCount: _visible.length,
                                itemBuilder: (context, i) {
                                  final e = _visible[i];
                                  return _EntryRow(
                                    entry: e,
                                    onTap: () => _play(e, playlist),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        focusColor: AppColors.accentSoft,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            border: selected
                ? null
                : Border.all(color: AppColors.divider, width: 1.2),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.onTap});

  final M3uEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      focusColor: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Row(
        children: [
          NetworkArtwork(
            url: entry.logo,
            width: 56,
            height: 56,
            fit: BoxFit.contain,
            fallbackIcon: Icons.live_tv_rounded,
            fallbackLabel: entry.name,
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium),
                if (entry.group != null)
                  Text(entry.group!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall),
              ],
            ),
          ),
          const Icon(Icons.play_arrow_rounded, color: AppColors.textTertiary),
        ],
      ),
    );
  }
}
