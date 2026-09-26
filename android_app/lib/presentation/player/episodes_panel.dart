import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/content.dart';
import '../../data/models/library.dart';
import '../widgets/network_artwork.dart';
import '../widgets/tv_text_gate.dart';
import '../widgets/watch_state.dart';

/// The in-player episode list: a panel over the video (which keeps
/// playing), with a season picker, search, the current episode highlighted
/// and scrolled to, and WATCHED / progress marks. Picking an episode returns
/// it; the player then plays it in place.
Future<Episode?> showEpisodesPanel(
  BuildContext context, {
  required SeriesDetail detail,
  required String currentEpisodeId,
  required HistoryEntry? Function(String key) historyFor,
}) {
  return showGeneralDialog<Episode>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close episodes',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, __) => _EpisodesPanel(
      detail: detail,
      currentEpisodeId: currentEpisodeId,
      historyFor: historyFor,
    ),
    transitionBuilder: (context, anim, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _EpisodesPanel extends StatefulWidget {
  const _EpisodesPanel({
    required this.detail,
    required this.currentEpisodeId,
    required this.historyFor,
  });

  final SeriesDetail detail;
  final String currentEpisodeId;
  final HistoryEntry? Function(String key) historyFor;

  @override
  State<_EpisodesPanel> createState() => _EpisodesPanelState();
}

class _EpisodesPanelState extends State<_EpisodesPanel> {
  static const _rowHeight = 92.0;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  late int _season;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final seasons = widget.detail.seasonNumbers;
    _season = seasons.isEmpty ? 0 : seasons.first;
    for (final n in seasons) {
      final list = widget.detail.seasons[n] ?? const <Episode>[];
      if (list.any((e) => e.id == widget.currentEpisodeId)) _season = n;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    if (!_scroll.hasClients) return;
    final i = _visible.indexWhere((e) => e.id == widget.currentEpisodeId);
    if (i <= 0) return;
    final target = (i - 1) * _rowHeight;
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
  }

  /// The chosen season, or every season's matches while searching.
  List<Episode> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.detail.seasons[_season] ?? const [];
    final out = <Episode>[];
    for (final n in widget.detail.seasonNumbers) {
      for (final e in widget.detail.seasons[n] ?? const <Episode>[]) {
        if (e.title.toLowerCase().contains(q) ||
            e.tag.toLowerCase().contains(q) ||
            '${e.episodeNumber}' == q) {
          out.add(e);
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width < 600 ? size.width * 0.92 : 460.0;
    final seasons = widget.detail.seasonNumbers;
    final episodes = _visible;

    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: const Color(0xF2141416),
        child: SafeArea(
          left: false,
          child: SizedBox(
            width: width,
            height: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Episodes',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TvTextGate(
                    builder: (node, done) => TextField(
                    focusNode: node,
                    onSubmitted: (_) => done(),
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(color: Colors.white),
                    cursorColor: AppColors.accent,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search episodes',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                      filled: true,
                      fillColor: const Color(0xFF232326),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  ),
                ),
                if (_query.isEmpty && seasons.length > 1)
                  SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                      itemCount: seasons.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final n = seasons[i];
                        return ChoiceChip(
                          label: Text('Season $n'),
                          selected: n == _season,
                          selectedColor: AppColors.accent,
                          onSelected: (_) => setState(() => _season = n),
                        );
                      },
                    ),
                  )
                else
                  const SizedBox(height: 10),
                Expanded(
                  child: episodes.isEmpty
                      ? const Center(
                          child: Text(
                            'No episodes match your search.',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          padding: const EdgeInsets.only(bottom: 12),
                          itemCount: episodes.length,
                          itemBuilder: (context, i) {
                            final e = episodes[i];
                            return _EpisodeRow(
                              episode: e,
                              current: e.id == widget.currentEpisodeId,
                              history: widget.historyFor(e.key),
                              autofocus: e.id == widget.currentEpisodeId,
                              onTap: () => Navigator.of(context).pop(e),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.current,
    required this.history,
    required this.autofocus,
    required this.onTap,
  });

  final Episode episode;
  final bool current;
  final HistoryEntry? history;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = history;
    final watched = h?.isWatched ?? false;
    final partial = h?.isContinueWatching ?? false;
    return Material(
      color: current ? AppColors.accent.withValues(alpha: 0.16) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        focusColor: Colors.white.withValues(alpha: 0.14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 63,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetworkArtwork(
                        url: episode.still,
                        width: 112,
                        height: 63,
                        borderRadius: BorderRadius.zero,
                        fallbackLabel: episode.tag,
                      ),
                      if (current)
                        const Center(
                          child: Icon(Icons.equalizer_rounded,
                              color: Colors.white, size: 28),
                        ),
                      if (partial)
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: FractionallySizedBox(
                            widthFactor: h!.progress.clamp(0.0, 1.0),
                            child: Container(
                                height: 3, color: AppColors.accent),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.tag,
                      style: TextStyle(
                        color: current ? AppColors.accent : AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (watched) ...[
                      const SizedBox(height: 4),
                      const WatchedMark(),
                    ] else if (current) ...[
                      const SizedBox(height: 4),
                      const Text(
                        'NOW PLAYING',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
