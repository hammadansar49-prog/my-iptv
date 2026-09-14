import 'package:flutter/material.dart';
import '../app_state.dart';
import '../artwork.dart';
import '../models.dart';
import '../theme.dart';
import '../xtream_client.dart';
import 'player_screen.dart';

class SeriesScreen extends StatefulWidget {
  final AppState state;
  final PlayableItem series;
  const SeriesScreen({super.key, required this.state, required this.series});

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  Map<String, dynamic>? info;
  bool loading = true;
  String? error;
  String? selectedSeason;

  @override
  void initState() {
    super.initState();
    widget.state.downloads.addListener(_onDlChanged);
    _load();
  }

  @override
  void dispose() {
    widget.state.downloads.removeListener(_onDlChanged);
    super.dispose();
  }

  void _onDlChanged() { if (mounted) setState(() {}); }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.state.client!.getSeriesInfo(widget.series.id);
      setState(() {
        info = data;
        loading = false;
        final episodes = data?['episodes'];
        if (episodes is Map && episodes.isNotEmpty) {
          selectedSeason = episodes.keys.first.toString();
        }
      });
    } catch (e) {
      setState(() {
        loading = false;
        error = e is XtreamException ? e.message : 'Could not load series info.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    return Scaffold(
      appBar: AppBar(title: Text(series.name)),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(error!, textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    ElevatedButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                )
              : _buildContent(),
    );
  }

  List<Map<String, dynamic>> _episodesOf(String season) {
    final raw = ((info?['episodes'] as Map?)?[season] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  PlayRequest _episodeRequest(Map<String, dynamic> ep, String season, List<Map<String, dynamic>> siblings, int index, List<PlayRequest> playlist) {
    final ext = ep['container_extension'] ?? 'mp4';
    final url = widget.state.client!.seriesEpisodeUrl('${ep['id']}', ext: ext);
    final req = PlayRequest(
      url: url,
      isLive: false,
      type: 'episode',
      title: widget.series.name,
      subtitle: 'Season $season - Episode ${ep['episode_num']} - ${ep['title'] ?? ''}',
      thumb: widget.series.thumb,
      historyKey: 'episode:${ep['id']}',
      playlist: playlist,
      playlistIndex: index,
    );
    final existing = widget.state.findHistory(req.historyKey);
    if (existing != null) req.resumeAt = existing.resumeAt;
    return req;
  }

  Widget _buildContent() {
    final episodesMap = (info?['episodes'] as Map?) ?? {};
    final seasons = episodesMap.keys.map((e) => e.toString()).toList();
    final plot = info?['info']?['plot'] ?? '';

    if (seasons.isEmpty) {
      return const Center(child: Text('No episodes found.', style: TextStyle(color: AppColors.textDim)));
    }

    final episodes = _episodesOf(selectedSeason!);
    final playlist = List.generate(episodes.length, (i) => _episodeRequest(episodes[i], selectedSeason!, episodes, i, const []));
    // playlist entries reference themselves circularly for auto-next; patch it in.
    for (final r in playlist) {
      final idx = playlist.indexOf(r);
      playlist[idx] = PlayRequest(
        url: r.url, isLive: false, type: r.type, title: r.title, subtitle: r.subtitle, thumb: r.thumb,
        historyKey: r.historyKey, resumeAt: r.resumeAt, playlist: playlist, playlistIndex: idx,
      );
    }

    // The series' own most-recently-touched episode (if any), so a "Resume:
    // Episode X" / "Start New" pair can be offered instead of making the
    // user hunt through seasons for where they left off.
    final seriesHistory = widget.state.history
        .where((h) => h.type == 'episode' && h.title == widget.series.name)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final lastWatched = seriesHistory.isEmpty ? null : seriesHistory.first;
    final epNumMatch = lastWatched == null ? null : RegExp(r'Episode\s+(\d+)', caseSensitive: false).firstMatch(lastWatched.subtitle);
    final isFinishedEp = lastWatched != null && lastWatched.duration > 0 && lastWatched.resumeAt >= lastWatched.duration * 0.95;
    final canResume = lastWatched != null && !isFinishedEp;

    void playFirstEpisode({double resumeAt = 0}) {
      final firstSeason = seasons.first;
      final eps = _episodesOf(firstSeason);
      if (eps.isEmpty) return;
      final req = _episodeRequest(eps.first, firstSeason, eps, 0, const []);
      if (resumeAt == 0) req.resumeAt = 0;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(state: widget.state, request: req)));
    }

    void resumeLastWatched() {
      final req = PlayRequest(
        url: lastWatched!.url, isLive: false, type: 'episode', title: lastWatched.title, subtitle: lastWatched.subtitle,
        thumb: lastWatched.thumb, historyKey: lastWatched.key, resumeAt: lastWatched.resumeAt,
      );
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(state: widget.state, request: req)));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(url: widget.series.thumb, title: widget.series.name, width: 90, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(plot, style: const TextStyle(fontSize: 12, color: AppColors.textDim), maxLines: 4, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: canResume ? resumeLastWatched : () => playFirstEpisode(),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: Text(canResume ? 'Resume: Ep ${epNumMatch?.group(1) ?? ''}' : lastWatched != null ? 'Play Next' : 'Play', style: const TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                        ),
                        if (canResume) ...[
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => playFirstEpisode(resumeAt: 0),
                            icon: const Icon(Icons.replay, size: 15),
                            label: const Text('Start New', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textDim,
                              side: const BorderSide(color: AppColors.border),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: seasons.map((s) {
                    final active = s == selectedSeason;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('Season $s'),
                        selected: active,
                        onSelected: (_) => setState(() => selectedSeason = s),
                        selectedColor: AppColors.accent,
                        backgroundColor: AppColors.bg2,
                        labelStyle: TextStyle(color: active ? Colors.white : AppColors.textDim, fontSize: 12),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: TextButton.icon(
                onPressed: () => _downloadSeason(episodes),
                icon: const Icon(Icons.download_outlined, size: 16),
                label: Text('Season $selectedSeason', style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: episodes.length,
            itemBuilder: (context, i) {
              final ep = episodes[i];
              final epInfo = ep['info'] is Map ? Map<String, dynamic>.from(ep['info']) : {};
              final thumb = epInfo['movie_image'] ?? widget.series.thumb;
              final req = playlist[i];
              final dl = widget.state.downloads.byUrl(req.url);
              return Card(
                color: AppColors.bg2,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Artwork(url: thumb, title: '', width: 80, radius: 6, placeholderIcon: Icons.movie_outlined),
                  title: Text('S$selectedSeason E${ep['episode_num']} - ${ep['title'] ?? ''}', style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: epInfo['duration'] != null ? Text('${epInfo['duration']}', style: const TextStyle(fontSize: 11, color: AppColors.textDim)) : null,
                  trailing: IconButton(
                    icon: Icon(
                      dl == null ? Icons.download_outlined : dl.status == 'completed' ? Icons.download_done : Icons.downloading,
                      color: dl?.status == 'downloading' ? AppColors.accent : AppColors.textDim,
                      size: 20,
                    ),
                    onPressed: () => _downloadOne(req),
                  ),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlayerScreen(state: widget.state, request: req))),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _downloadOne(PlayRequest req) {
    final existing = widget.state.downloads.byUrl(req.url);
    if (existing != null) return;
    widget.state.downloads.add(url: req.url, title: req.title, subtitle: req.subtitle, type: 'episode', thumb: req.thumb);
  }

  void _downloadSeason(List<Map<String, dynamic>> episodes) {
    int added = 0;
    for (var i = 0; i < episodes.length; i++) {
      final req = _episodeRequest(episodes[i], selectedSeason!, episodes, i, const []);
      if (widget.state.downloads.byUrl(req.url) == null) {
        widget.state.downloads.add(url: req.url, title: req.title, subtitle: req.subtitle, type: 'episode', thumb: req.thumb);
        added++;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(added > 0 ? '$added episode${added == 1 ? '' : 's'} added to Downloads.' : 'This season is already downloaded.'),
    ));
  }
}
