import 'dart:io';
import 'package:flutter/material.dart';
import '../license.dart';
import '../theme.dart';

/// Checks the SAME `iptv/update` RTDB node the PC app reads. The admin panel
/// sets a `platform` field ("pc", "android", or "all") per update entry —
/// this app only ever surfaces one meant for "android" or "all", so
/// publishing a PC-only update never falsely flags this app as outdated.
/// `force_update` blocks dismissal, matching how the PC app treats it.
Future<void> maybeShowUpdate(
  BuildContext context,
  LicenseService license, {
  // `force` bypasses LicenseService's warm cache for a genuinely fresh
  // read — used by the manual "Check for Update" row in Profile so it
  // doesn't just re-report whatever was cached at app launch.
  // `announceIfCurrent` shows a snackbar when there's nothing new, which the
  // silent launch-time check (main_shell.dart) deliberately doesn't want.
  bool force = false,
  bool announceIfCurrent = false,
  }) async {
  final result = await license.checkForUpdate(force: force).catchError((_) => <String, dynamic>{'available': false});
  if (result['available'] != true) {
    if (announceIfCurrent && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("You're on the latest version (v${result['currentVersion'] ?? ''}).")),
      );
    }
    return;
  }
  if (!context.mounted) return;

  final forceUpdate = result['forceUpdate'] == true;
  final downloadUrl = (result['downloadUrl'] as String?) ?? '';
  final notes = (result['notes'] as String?) ?? '';
  final latestVersion = (result['latestVersion'] as String?) ?? '';

  await showDialog(
    context: context,
    barrierDismissible: !forceUpdate,
    builder: (ctx) => PopScope(
      canPop: !forceUpdate,
      child: AlertDialog(
        backgroundColor: AppColors.bg2,
        title: Text('Update available · v$latestVersion'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (notes.isNotEmpty) Text(notes),
              if (forceUpdate) ...[
                const SizedBox(height: 12),
                const Text('This update is required to continue using the app.',
                    style: TextStyle(color: AppColors.danger, fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          if (!forceUpdate) TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Later')),
          if (forceUpdate && downloadUrl.isEmpty)
            TextButton(onPressed: () => exit(0), child: const Text('Exit App')),
          ElevatedButton(
            onPressed: downloadUrl.isEmpty ? null : () async {
              final ok = await license.openUpdateLink(downloadUrl);
              if (!ok && ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text("Couldn't open the update link. Please check your browser.")),
                );
              }
            },
            child: const Text('Update Now'),
          ),
        ],
      ),
    ),
  );
}
