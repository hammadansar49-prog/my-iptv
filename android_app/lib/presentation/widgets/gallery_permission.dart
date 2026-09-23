import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/permissions/permission_service.dart';

/// Gate in front of every new download: finished downloads are published to
/// the Gallery (Movies/MY IPTV), which needs media access. Explains first,
/// then shows the system dialog. Returns true only when access is granted;
/// otherwise says so and nothing is downloaded.
Future<bool> ensureGalleryPermission(BuildContext context) async {
  var status = await PermissionService.status(AppPermission.media);
  if (status == AppPermissionStatus.granted) return true;
  if (!context.mounted) return false;

  final blocked = status == AppPermissionStatus.permanentlyDenied;
  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surfaceHigh,
      icon: const Icon(Icons.video_library_rounded,
          color: AppColors.accent, size: 36),
      title: const Text('Save downloads to your Gallery'),
      content: Text(
        blocked
            ? 'Media access is turned off for MY IPTV. Allow it in Settings '
                '(Permissions > Videos) so downloads can be saved to '
                'Movies/MY IPTV.'
            : 'Downloaded movies and episodes are saved to your Gallery in '
                'Movies/MY IPTV, so you can watch them offline in this app '
                'or any video player. Android will ask you to allow access '
                'to videos.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(blocked ? 'Open settings' : 'Continue'),
        ),
      ],
    ),
  );
  if (proceed != true) {
    if (context.mounted) _denied(context);
    return false;
  }

  if (blocked) {
    await PermissionService.openSettings(AppPermission.media);
    return false;
  }

  status = await PermissionService.request(AppPermission.media);
  if (status == AppPermissionStatus.granted) return true;
  if (context.mounted) _denied(context);
  return false;
}

void _denied(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text(
          'Download not started: MY IPTV needs access to videos to save it '
          'to your Gallery.',
        ),
        duration: Duration(seconds: 4),
      ),
    );
}

