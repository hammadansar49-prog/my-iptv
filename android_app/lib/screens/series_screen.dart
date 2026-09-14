import 'package:flutter/material.dart';
import '../app_state.dart';
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
    _load();
  }

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

  Widget _buildContent() {
    final episodesMap = (info?['episodes'] as Map?) ?? {};
    final seasons = episodesMap.keys.map((e) => e.toString()).toList();
    final plot = info?['info']?['plot'] ?? '';

    if (seasons.isEmpty) {
      return const Center(child: Text('No episodes found.', style: TextStyle(color: AppColors.textDim)));
    }

    final episodes = (episodesMap[selectedSeason] as List?) ?? [];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 90, height: 130,
                  child: widget.series.thumb.isNotEmpty
                      ? Image.network(widget.series.thumb, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(color: AppColors.bg3))
                      : Container(color: AppColors.bg3),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(plot, style: const TextStyle(fontSize: 12, color: AppColors.textDim), maxLines: 6, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        SizedBox(
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
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: episodes.length,
            itemBuilder: (context, i) {
              final ep = Map<String, dynamic>.from(episodes[i]);
              final epInfo = ep['info'] is Map ? Map<String, dynamic>.from(ep['info']) : {};
              final thumb = epInfo['movie_image'] ?? widget.series.thumb;
              return Card(
                color: AppColors.bg2,
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 80, height: 46,
                      child: thumb != null && thumb.toString().isNotEmpty
                          ? Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppColors.bg3))
                          : Container(color: AppColors.bg3),
                    ),
                  ),
                  title: Text('S$selectedSeason E${ep['episode_num']} - ${ep['title'] ?? ''}', style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: epInfo['duration'] != null ? Text('${epInfo['duration']}', style: const TextStyle(fontSize: 11, color: AppColors.textDim)) : null,
                  onTap: () => _playEpisode(ep),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _playEpisode(Map<String, dynamic> ep) {
    final ext = ep['container_extension'] ?? 'mp4';
    final url = widget.state.client!.seriesEpisodeUrl('${ep['id']}', ext: ext);
    final req = PlayRequest(
      url: url,
      isLive: false,
      type: 'episode',
      title: widget.series.name,
      subtitle: 'Season $selectedSeason - Episode ${ep['episode_num']} - ${ep['title'] ?? ''}',
      thumb: widget.series.thumb,
      historyKey: 'episode:${ep['id']}',
    );
    final existing = widget.state.findHistory(req.historyKey);
    if (existing != null) req.resumeAt = existing.resumeAt;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(state: widget.state, request: req),
    ));
  }
}
