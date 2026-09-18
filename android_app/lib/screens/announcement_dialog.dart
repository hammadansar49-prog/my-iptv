import 'dart:async';
import 'package:flutter/material.dart';
import '../license.dart';
import '../notifications.dart';
import '../storage.dart';
import '../theme.dart';

/// Shows the admin-set in-app announcement (same `iptv/announcement` RTDB
/// node the PC app reads) once per announcement — tracked by its
/// `created_at` so editing/replacing it in the admin panel shows the new
/// one again even if the old one was already dismissed. Optional star +
/// comment feedback, only collected when the admin turns on
/// `collect_feedback` for that announcement.
Future<void> maybeShowAnnouncement(BuildContext context, LicenseService license) async {
  final data = await license.getAnnouncement();
  if (data == null) return;
  final createdAt = (data['created_at'] as num?)?.toInt() ?? 0;
  final dismissedAt = Storage.p.getInt('announcementDismissed') ?? 0;
  if (createdAt != 0 && createdAt == dismissedAt) return;

  // System notification, separate from the in-app dialog below — this
  // function gets called more than once for the same still-undismissed
  // announcement (launch check, live SSE push, a reconnect resending
  // unchanged data), but the notification itself should only fire once per
  // announcement, tracked by createdAt the same way dismissal is.
  final notifiedAt = Storage.p.getInt('announcementNotified') ?? 0;
  if (createdAt != 0 && createdAt != notifiedAt) {
    await Storage.p.setInt('announcementNotified', createdAt);
    unawaited(AppNotifications.showAnnouncement(
      data['title']?.toString().isNotEmpty == true ? data['title'].toString() : 'MY IPTV',
      data['text'].toString(),
    ));
  }

  if (!context.mounted) return;

  final collectFeedback = data['collect_feedback'] == true;
  int rating = 0;
  final commentController = TextEditingController();

  await showDialog(
    context: context,
    builder: (_) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: AppColors.bg2,
            title: Text(data['title']?.toString().isNotEmpty == true ? data['title'].toString() : 'Announcement'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((data['text']?.toString() ?? '')),
                  if (collectFeedback) ...[
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) => IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(i < rating ? Icons.star : Icons.star_border, color: AppColors.accent),
                            onPressed: () => setState(() => rating = i + 1),
                          )),
                    ),
                    if (rating > 0)
                      TextField(
                        controller: commentController,
                        maxLines: 2,
                        decoration: const InputDecoration(isDense: true, hintText: 'Add a comment (optional)'),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              if (collectFeedback && rating > 0)
                TextButton(
                  onPressed: () async {
                    try {
                      await license.submitAnnouncementReview(rating: rating, comment: commentController.text, announcementCreatedAt: createdAt);
                    } catch (_) {}
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('Submit'),
                ),
              TextButton(onPressed: () { Navigator.of(ctx).pop(); }, child: const Text('Close')),
            ],
          );
        },
      );
    },
  ).then((_) => commentController.dispose());

  if (createdAt != 0) await Storage.p.setInt('announcementDismissed', createdAt);
}
