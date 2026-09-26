import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/logger.dart';
import '../../data/api/rtdb_api.dart';
import '../../services/player/pip_service.dart';
import '../providers.dart';
import 'iptv_live_controller.dart';

/// Sits above the router's Navigator (installed from MaterialApp.router's
/// `builder`), so whatever it shows covers every route — including the
/// fullscreen landscape player, which is where a dialog pushed on the
/// navigator would be awkward or hidden. Its own [Overlay] gives the
/// feedback TextField the ancestor it needs for selection handles.
class IptvLiveLayer extends ConsumerStatefulWidget {
  const IptvLiveLayer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IptvLiveLayer> createState() => _IptvLiveLayerState();
}

class _IptvLiveLayerState extends ConsumerState<IptvLiveLayer> {
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => const _LiveSurfaces());

  @override
  void didUpdateWidget(IptvLiveLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) {
    // Watching here is what starts the streams, once, after bootstrap.
    ref.watch(iptvLiveProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // In Picture-in-Picture the window shows only the video: no
        // announcement or update surfaces over it. Offstage keeps their state.
        ValueListenableBuilder<bool>(
          valueListenable: PipService.inPip,
          builder: (context, pip, child) =>
              Offstage(offstage: pip, child: child),
          child: Overlay(initialEntries: [_entry]),
        ),
      ],
    );
  }
}

class _LiveSurfaces extends ConsumerWidget {
  const _LiveSurfaces();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(iptvLiveProvider);
    final ann = live.announcement;
    final update = live.update;

    // Priority: licence block > forced update > announcement > update prompt.
    // Only one blocking surface at a time; lesser ones wait behind it.
    Widget? top;
    if (live.licenseBlocked) {
      top = _SubscriptionEnded(whatsapp: live.whatsappNumber);
    } else if (live.forceUpdate && update != null) {
      top = _ForceUpdate(info: update, current: live.currentVersion);
    } else if (ann != null) {
      top = _AnnouncementModal(
        key: ValueKey('${ann.createdAt}|${ann.text}'),
        announcement: ann,
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          if (top == null && live.showUpdatePrompt && update != null)
            Positioned(
              left: Insets.lg,
              right: Insets.lg,
              bottom: Insets.lg,
              child: SafeArea(top: false, child: _UpdatePrompt(info: update)),
            ),
          // The opaque detector is the modal barrier: taps outside the card
          // must not reach the app underneath.
          if (top != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: FocusScope(autofocus: true, child: top),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- Shared bits -------------------------------------------------------------

Future<void> openUpdateUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  // Only http(s): the admin field is free text and must never become an
  // intent:// or file:// launch.
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    _toast(context, 'No download link has been published yet.');
    return;
  }
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    Log.w('IptvLive', 'launch failed: $e');
  }
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.all(Insets.xl),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: AppColors.divider),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon);
  final IconData icon;
  static const color = AppColors.accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Icon(icon, color: color, size: 30),
    );
  }
}

// ---- Announcement -------------------------------------------------------------

class _AnnouncementModal extends ConsumerStatefulWidget {
  const _AnnouncementModal({super.key, required this.announcement});
  final Announcement announcement;

  @override
  ConsumerState<_AnnouncementModal> createState() => _AnnouncementModalState();
}

class _AnnouncementModalState extends ConsumerState<_AnnouncementModal> {
  int _stars = 0;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ann = widget.announcement;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.7),
      child: _Card(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(alignment: Alignment.centerLeft, child: _Badge(Icons.campaign_rounded)),
            const SizedBox(height: Insets.lg),
            Text('Announcement', style: text.titleLarge),
            const SizedBox(height: Insets.md),
            Text(ann.text, style: text.bodyMedium?.copyWith(color: AppColors.textPrimary)),
            if (ann.collectFeedback) ...[
              const SizedBox(height: Insets.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var n = 1; n <= 5; n++)
                    IconButton(
                      onPressed: () => setState(() => _stars = n),
                      icon: Icon(
                        n <= _stars ? Icons.star_rounded : Icons.star_outline_rounded,
                        color: n <= _stars ? AppColors.tileYellow : AppColors.textTertiary,
                        size: 32,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: Insets.sm),
              TextField(
                controller: _comment,
                minLines: 2,
                maxLines: 4,
                maxLength: 1000,
                decoration: const InputDecoration(
                  hintText: "Anything you'd like to add? (optional)",
                  counterText: '',
                ),
              ),
            ],
            const SizedBox(height: Insets.lg),
            FilledButton(
              autofocus: true,
              onPressed: () => ref
                  .read(iptvLiveProvider)
                  .dismissAnnouncement(rating: _stars, comment: _comment.text),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Subscription ended -------------------------------------------------------

class _SubscriptionEnded extends ConsumerWidget {
  const _SubscriptionEnded({required this.whatsapp});
  final String? whatsapp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    var digits = (whatsapp ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) digits = '923341100761';
    const renew = 'Hi, I would like to renew my MY IPTV subscription.';
    // Android TV has no WhatsApp: show the number and a QR code right here
    // (this screen sits above the Navigator, so no dialog).
    final tv = ref.watch(isTvProvider);
    // Opaque and swallowing every touch: the app underneath must not be
    // usable, and there is deliberately no close button.
    return ColoredBox(
        color: AppColors.background,
        child: _Card(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(alignment: Alignment.centerLeft, child: _Badge(Icons.lock_clock_rounded)),
              const SizedBox(height: Insets.lg),
              Text('Subscription ended', style: text.titleLarge),
              const SizedBox(height: Insets.md),
              Text(
                'Your subscription has expired or was ended. Contact us on '
                'WhatsApp to renew — the app unlocks by itself as soon as it is renewed.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: Insets.xl),
              if (tv)
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      color: Colors.white,
                      child: QrImageView(
                        data: 'https://wa.me/$digits?text=${Uri.encodeComponent(renew)}',
                        size: 160,
                      ),
                    ),
                    const SizedBox(width: Insets.lg),
                    Expanded(
                      child: Text(
                        'WhatsApp: +$digits\nName: theottdeals\n\n'
                        'Scan with your phone to message us for renewal.',
                        style: text.bodyLarge,
                      ),
                    ),
                  ],
                )
              else
                FilledButton.icon(
                  autofocus: true,
                  onPressed: () => launchUrl(
                    Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(renew)}'),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.chat_rounded),
                  label: const Text('Contact on WhatsApp'),
                ),
            ],
          ),
        ),
    );
  }
}

// ---- Updates ------------------------------------------------------------------

class _ForceUpdate extends StatelessWidget {
  const _ForceUpdate({required this.info, required this.current});
  final UpdateInfo info;
  final String current;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: AppColors.background,
      child: _Card(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(alignment: Alignment.centerLeft, child: _Badge(Icons.system_update_rounded)),
            const SizedBox(height: Insets.lg),
            Text('Update required', style: text.titleLarge),
            const SizedBox(height: Insets.md),
            Text(
              'Version ${info.version} is required to keep using the app '
              '(you have $current).',
              style: text.bodyMedium,
            ),
            if (info.notes.trim().isNotEmpty) ...[
              const SizedBox(height: Insets.md),
              Text(info.notes.trim(), style: text.bodySmall),
            ],
            const SizedBox(height: Insets.xl),
            FilledButton(
              autofocus: true,
              onPressed: () => openUpdateUrl(context, info.downloadUrl),
              child: const Text('Download update'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdatePrompt extends ConsumerWidget {
  const _UpdatePrompt({required this.info});
  final UpdateInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.xs, Insets.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: AppColors.accent),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text('Version ${info.version} is available.',
                style: text.bodyMedium?.copyWith(color: AppColors.textPrimary)),
          ),
          TextButton(
            onPressed: () => openUpdateUrl(context, info.downloadUrl),
            child: const Text('Update', style: TextStyle(color: AppColors.accent)),
          ),
          IconButton(
            onPressed: () => ref.read(iptvLiveProvider).dismissUpdatePrompt(),
            icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Profile → Check Updates. A fresh read of `iptv/update`, not the stream's
/// cache (see [RtdbApi.update]).
Future<void> checkForUpdatesManually(BuildContext context, WidgetRef ref) async {
  final live = ref.read(iptvLiveProvider);
  final current = live.currentVersion;
  UpdateInfo? info;
  try {
    info = await ref.read(rtdbApiProvider).update();
  } catch (e) {
    if (context.mounted) _toast(context, 'Could not check for updates. Check your connection.');
    return;
  }
  if (!context.mounted) return;
  final newer = info != null &&
      info.appliesToAndroid &&
      current.isNotEmpty &&
      compareVersions(info.version, current) > 0;
  final found = newer ? info : null;
  if (found == null) {
    _toast(context, "You're on the latest version${current.isEmpty ? '' : ' ($current)'}.");
    return;
  }
  final text = Theme.of(context).textTheme;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
    ),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Update available', style: text.titleLarge),
            const SizedBox(height: Insets.sm),
            Text('Version ${found.version} · you have $current', style: text.bodySmall),
            if (found.notes.trim().isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(found.notes.trim(),
                      style: text.bodyMedium?.copyWith(color: AppColors.textPrimary)),
                ),
              ),
            ],
            const SizedBox(height: Insets.xl),
            FilledButton(
              autofocus: true,
              onPressed: () => openUpdateUrl(sheet, found.downloadUrl),
              child: const Text('Download update'),
            ),
          ],
        ),
      ),
    ),
  );
}
