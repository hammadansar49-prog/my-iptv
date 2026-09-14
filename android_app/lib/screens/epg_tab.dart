import 'package:flutter/material.dart';
import '../app_state.dart';
import '../artwork.dart';
import '../models.dart';
import '../theme.dart';
import 'live_tv_screen.dart';

/// A channel guide: search live channels, tap to watch, tap the clock icon
/// for what's on now / next (pulled from the provider's short EPG on
/// demand, not for all 15,000+ channels up front).
class EpgTab extends StatefulWidget {
  final AppState state;
  const EpgTab({super.key, required this.state});

  @override
  State<EpgTab> createState() => _EpgTabState();
}

class _EpgTabState extends State<EpgTab> {
  List<PlayableItem>? channels;
  String? error;
  String search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      channels = null;
      error = null;
    });
    try {
      final list = await widget.state.sectionItems('live', force: force);
      if (!mounted) return;
      setState(() => channels = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = 'Could not load channels.');
    }
  }

  void _play(PlayableItem ch) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveTvScreen(state: widget.state, channels: channels ?? [ch], initial: ch)));
  }

  Future<void> _showEpg(PlayableItem ch) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      isScrollControlled: true,
      builder: (_) => _EpgSheet(state: widget.state, channel: ch, onPlay: () { Navigator.pop(context); _play(ch); }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load(force: true))],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              onChanged: (v) => setState(() => search = v),
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(isDense: true, hintText: 'Search channels...', prefixIcon: Icon(Icons.search, size: 18)),
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(error!),
          const SizedBox(height: 10),
          ElevatedButton(onPressed: () => _load(force: true), child: const Text('Retry')),
        ]),
      );
    }
    if (channels == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final list = search.isEmpty ? channels! : channels!.where((c) => c.name.toLowerCase().contains(search.toLowerCase())).toList();
    if (list.isEmpty) {
      return const Center(child: Text('No channels found.', style: TextStyle(color: AppColors.textDim)));
    }
    // Same grid the Live TV pill on Home uses, so this tab is just another
    // door into the same channels — plus a schedule icon on each card for
    // what's on now / next.
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220, childAspectRatio: 16 / 11, crossAxisSpacing: 10, mainAxisSpacing: 10,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final ch = list[i];
        final faved = widget.state.isFavorite('live', ch);
        return GestureDetector(
          onTap: () => _play(ch),
          child: Container(
            decoration: cardDecoration(radius: 10),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(child: Artwork(url: ch.thumb, title: ch.name, width: 220, fit: BoxFit.contain, placeholderIcon: Icons.live_tv)),
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(.85)])),
                    child: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
                Positioned(
                  top: 4, right: 4,
                  child: Row(children: [
                    _miniIcon(Icons.schedule, () => _showEpg(ch)),
                    const SizedBox(width: 4),
                    _miniIcon(faved ? Icons.favorite : Icons.favorite_border, () async { await widget.state.toggleFavorite('live', ch); setState(() {}); }, color: faved ? const Color(0xFFFF5D7A) : Colors.white),
                  ]),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _miniIcon(IconData icon, VoidCallback onTap, {Color color = Colors.white}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26, height: 26,
        decoration: BoxDecoration(color: Colors.black.withOpacity(.55), shape: BoxShape.circle),
        child: Icon(icon, size: 13, color: color),
      ),
    );
  }
}

class _EpgSheet extends StatefulWidget {
  final AppState state;
  final PlayableItem channel;
  final VoidCallback onPlay;
  const _EpgSheet({required this.state, required this.channel, required this.onPlay});

  @override
  State<_EpgSheet> createState() => _EpgSheetState();
}

class _EpgSheetState extends State<_EpgSheet> {
  List<EpgEntry>? entries;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    widget.state.client!.getShortEpg(widget.channel.id, limit: 4).then((list) {
      if (mounted) setState(() => entries = list);
    }).catchError((_) {
      if (mounted) setState(() => failed = true);
    });
  }

  String _time(int unixSec) {
    final d = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.channel.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(onPressed: widget.onPlay, icon: const Icon(Icons.play_arrow, size: 16), label: const Text('Watch')),
              ],
            ),
            const SizedBox(height: 14),
            if (entries == null && !failed) const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Center(child: CircularProgressIndicator())),
            if (failed || (entries != null && entries!.isEmpty))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No program guide data from this provider for this channel.', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
              ),
            if (entries != null)
              ...entries!.map((e) {
                final now = e.isNow(nowSec);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 46, child: Text(_time(e.start), style: TextStyle(fontSize: 12, color: now ? AppColors.accent : AppColors.textDim, fontWeight: now ? FontWeight.w700 : FontWeight.normal))),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              if (now) Container(margin: const EdgeInsets.only(right: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(4)), child: const Text('NOW', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold))),
                              Expanded(child: Text(e.title.isEmpty ? 'Programme' : e.title, style: TextStyle(fontSize: 13, fontWeight: now ? FontWeight.w700 : FontWeight.w500))),
                            ]),
                            if (e.description.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(e.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
