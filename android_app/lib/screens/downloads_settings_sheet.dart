import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../theme.dart';

class DownloadsSettingsSheet extends StatefulWidget {
  final AppState state;
  const DownloadsSettingsSheet({super.key, required this.state});

  @override
  State<DownloadsSettingsSheet> createState() => _DownloadsSettingsSheetState();
}

class _DownloadsSettingsSheetState extends State<DownloadsSettingsSheet> {
  String? error;

  Future<void> _changeFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose where downloads are saved');
    if (path == null) return;
    final err = await widget.state.downloads.setDir(path);
    setState(() => error = err);
    if (err == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download folder changed.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.state.downloads;
    return DraggableScrollableSheet(
      initialChildSize: .6,
      minChildSize: .4,
      maxChildSize: .85,
      expand: false,
      builder: (context, scroll) => Container(
        decoration: const BoxDecoration(color: AppColors.bg2, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Downloads', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const Divider(height: 24, color: AppColors.border),
            const Text('DOWNLOAD LOCATION', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: cardDecoration(radius: 10, color: AppColors.bg3),
              child: Text(d.dir, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error!, style: const TextStyle(color: AppColors.danger, fontSize: 11))),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: _changeFolder, icon: const Icon(Icons.folder_open, size: 16), label: const Text('Change folder')),
            const SizedBox(height: 22),
            const Text('WHILE WATCHING ONLINE', style: TextStyle(color: AppColors.textDim, fontSize: 11, letterSpacing: .5)),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep downloading while watching', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              subtitle: const Text(
                'One download runs at a time, at the full speed of the connection. It keeps going while you watch — the provider may briefly drop it, and it reconnects by itself. Turn this off if playback ever stutters while something downloads.',
                style: TextStyle(color: AppColors.textDim, fontSize: 11),
              ),
              value: d.whileWatching,
              onChanged: (v) async { await d.setWhileWatching(v); setState(() {}); },
            ),
          ],
        ),
      ),
    );
  }
}
