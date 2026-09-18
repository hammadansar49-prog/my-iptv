import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';

const _sections = {'movies': 'Movies', 'series': 'Series', 'live': 'Live TV'};
const _refreshOptions = {'never': 'Never', '6h': 'Every 6 hours', '1day': 'Every day', '1week': 'Every 1 week'};
const _liveFormats = {'m3u8': 'HLS (recommended)', 'ts': 'MPEG-TS'};
const _seekSteps = {10: '10 sec', 15: '15 sec', 30: '30 sec'};

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
                const Expanded(child: Text('Advanced Settings', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const Text('Customize how Home opens and how playback behaves', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
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
                  onSelected: (_) { s.setStr('defaultSection', e.key); setState(() {}); },
                  selectedColor: AppColors.accent,
                  backgroundColor: AppColors.bg3,
                  labelStyle: TextStyle(color: active ? Colors.white : AppColors.textDim, fontWeight: FontWeight.w600, fontSize: 12),
                );
              }).toList(),
            ),

            const SizedBox(height: 22),
            const Text('PLAYBACK', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Resume where you left off', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              subtitle: const Text('Movies and episodes reopen at your saved position.', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
              value: s.resume,
              onChanged: (v) => setState(() => s.setFlag('resume', v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-play next episode', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              subtitle: const Text('Rolls into the next episode in the season when one finishes.', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
              value: s.autoNext,
              onChanged: (v) => setState(() => s.setFlag('autoNext', v)),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                title: const Text('Skip / seek step', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                trailing: DropdownButton<int>(
                  value: _seekSteps.containsKey(s.seekStep) ? s.seekStep : _seekSteps.keys.first,
                  dropdownColor: AppColors.bg3,
                  underline: const SizedBox(),
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                  items: _seekSteps.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) { if (v != null) setState(() => s.setStr('seekStep', '$v')); },
                ),
              ),
            ),

            const SizedBox(height: 22),
            const Text('LIVE TV', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                title: const Text('Stream format', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                subtitle: const Text('HLS plays smoothest on most providers.', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                trailing: DropdownButton<String>(
                  value: _liveFormats.containsKey(s.liveFormat) ? s.liveFormat : _liveFormats.keys.first,
                  dropdownColor: AppColors.bg3,
                  underline: const SizedBox(),
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                  items: _liveFormats.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) { if (v != null) setState(() => s.setStr('liveFormat', v)); },
                ),
              ),
            ),

            const SizedBox(height: 22),
            const Text('CONTENT REFRESH', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(10)),
              child: ListTile(
                title: const Text('Refresh Xtream', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                subtitle: const Text('Catalog is cached for 10 minutes either way.', style: TextStyle(color: AppColors.textDim, fontSize: 11)),
                trailing: DropdownButton<String>(
                  value: _refreshOptions.containsKey(s.refreshInterval) ? s.refreshInterval : _refreshOptions.keys.first,
                  dropdownColor: AppColors.bg3,
                  underline: const SizedBox(),
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                  items: _refreshOptions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) { if (v != null) setState(() => s.setStr('refreshInterval', v)); },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
