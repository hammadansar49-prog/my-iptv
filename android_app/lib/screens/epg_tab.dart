import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import 'player_screen.dart';

/// A simple channel guide: search live channels, tap to play. (Full
/// per-timeslot program data depends on the provider's EPG feed quality —
/// many panels don't populate it reliably, so this keeps the guide list
/// fast and always useful rather than showing empty timeslots.)
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

  Future<void> _load() async {
    setState(() {
      channels = null;
      error = null;
    });
    try {
      final list = await widget.state.client!.getLiveStreams(null);
      if (!mounted) return;
      setState(() => channels = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = 'Could not load channels.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG'),
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
          ElevatedButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    if (channels == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final list = search.isEmpty
        ? channels!
        : channels!.where((c) => c.name.toLowerCase().contains(search.toLowerCase())).toList();
    if (list.isEmpty) {
      return const Center(child: Text('No channels found.', style: TextStyle(color: AppColors.textDim)));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
      itemBuilder: (context, i) {
        final ch = list[i];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 48, height: 48, color: AppColors.bg3,
              child: ch.thumb.isNotEmpty
                  ? Image.network(ch.thumb, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.live_tv, color: AppColors.textDim))
                  : const Icon(Icons.live_tv, color: AppColors.textDim),
            ),
          ),
          title: Text(ch.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: const Text('Tap to watch live', style: TextStyle(fontSize: 11, color: AppColors.textDim)),
          trailing: const Icon(Icons.play_circle_fill, color: AppColors.accent),
          onTap: () {
            final url = widget.state.client!.liveUrl(ch.id, ext: 'm3u8');
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PlayerScreen(
                state: widget.state,
                request: PlayRequest(url: url, isLive: true, type: 'live', title: ch.name, subtitle: 'Live TV', thumb: ch.thumb, historyKey: 'live:${ch.id}'),
                favSection: 'live',
                favItem: ch,
              ),
            ));
          },
        );
      },
    );
  }
}
