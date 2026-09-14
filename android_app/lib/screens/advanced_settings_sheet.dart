import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';

const _sections = {'all': 'All', 'movies': 'Movies', 'series': 'Series', 'live': 'Live TV'};
const _players = {
  'internal': ('Default Player', 'Native player · Picture in Picture', Icons.smart_display),
  'vlc': ('VLC Player', 'Opens the stream in the VLC app if installed', Icons.play_circle_fill),
};
const _refreshOptions = {'never': 'Never', '6h': 'Every 6 hours', '1day': 'Every day', '1week': 'Every 1 week'};

class AdvancedSettingsSheet extends StatefulWidget {
  final AppState state;
  const AdvancedSettingsSheet({super.key, required this.state});

  @override
  State<AdvancedSettingsSheet> createState() => _AdvancedSettingsSheetState();
}

class _AdvancedSettingsSheetState extends State<AdvancedSettingsSheet> {
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return DraggableScrollableSheet(
      initialChildSize: .82,
      minChildSize: .5,
      maxChildSize: .95,
      expand: false,
      builder: (context, scroll) => Container(
        decoration: const BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Advanced Settings', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const Text('Customize how Home opens and which player is used', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            const Divider(height: 28, color: AppColors.border),

            const Text('LOAD CONTENT BY DEFAULT', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: _sections.entries.map((e) {
                final active = s.defaultSection == e.key;
                return ChoiceChip(
                  label: Text(e.value),
                  selected: active,
                  onSelected: (_) => setState(() => s.setDefaultSection(e.key)),
                  selectedColor: AppColors.accent,
                  backgroundColor: AppColors.bg3,
                  labelStyle: TextStyle(color: active ? Colors.white : AppColors.textDim, fontWeight: FontWeight.w600, fontSize: 12),
                );
              }).toList(),
            ),

            const SizedBox(height: 26),
            const Text('DEFAULT PLAYER', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 10),
            ..._players.entries.map((e) {
              final active = s.defaultPlayer == e.key;
              final (title, subtitle, icon) = e.value;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: active ? AppColors.accent.withOpacity(.15) : AppColors.bg3,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: active ? AppColors.accent : AppColors.border),
                ),
                child: ListTile(
                  leading: Icon(icon, color: active ? AppColors.accent : AppColors.textDim),
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  subtitle: Text(subtitle, style: const TextStyle(color: AppColors.textDim, fontSize: 11)),
                  trailing: active ? const Icon(Icons.check, color: AppColors.accent) : null,
                  onTap: () => setState(() => s.setDefaultPlayer(e.key)),
                ),
              );
            }),

            const SizedBox(height: 18),
            const Text('CONTENT REFRESH', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                title: const Text('Refresh Xtream', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                trailing: DropdownButton<String>(
                  value: s.refreshInterval,
                  dropdownColor: AppColors.bg3,
                  underline: const SizedBox(),
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                  items: _refreshOptions.entries
                      .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => s.setRefreshInterval(v));
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
