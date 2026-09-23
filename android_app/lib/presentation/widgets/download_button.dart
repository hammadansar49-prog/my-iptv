import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/library.dart';
import '../../services/download/download_manager.dart';
import '../providers.dart';

enum _Phase { idle, pending, running, paused, done }

/// A download control that reflects the real state of the download for
/// [url], wherever it is shown (movie detail, episode rows).
///
///  * idle — a download arrow. Tapping starts the download and the arrow
///    morphs into a small stop-dot with a progress ring around it.
///  * queued / connecting — the ring spins.
///  * downloading — the ring fills with the real received bytes.
///  * tapping the dot cancels: the download is removed, its partial file
///    deleted, and the arrow comes back.
///  * completed — a check.
class DownloadButton extends ConsumerWidget {
  const DownloadButton({
    super.key,
    required this.url,
    required this.buildRequest,
    this.diameter = 40,
    this.showLabel = false,
    this.background,
  });

  /// The stream URL — what the download manager keys items on.
  final String url;

  /// Built only when the user actually taps Download.
  final DownloadRequest Function() buildRequest;

  final double diameter;

  /// Icon-over-label layout (movie detail) instead of a bare circle.
  final bool showLabel;

  /// Fill behind the circular control; null for none.
  final Color? background;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    DownloadItem? item;
    for (final it in ref.watch(downloadListProvider)) {
      if (it.url == url) {
        item = it;
        break;
      }
    }
    final phase = switch (item?.status) {
      null || DownloadStatus.failed => _Phase.idle,
      DownloadStatus.queued || DownloadStatus.waiting => _Phase.pending,
      DownloadStatus.downloading => _Phase.running,
      DownloadStatus.paused => _Phase.paused,
      DownloadStatus.completed => _Phase.done,
    };
    final progress = item?.progress ?? 0;

    Future<void> onTap() async {
      final manager = ref.read(downloadManagerProvider);
      final messenger = ScaffoldMessenger.of(context);
      HapticFeedback.selectionClick();
      switch (phase) {
        case _Phase.idle:
          await manager.add(buildRequest());
        case _Phase.pending || _Phase.running || _Phase.paused:
          await manager.remove(item!.id);
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Download cancelled')));
        case _Phase.done:
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(
                content: Text('Already downloaded — find it in Downloads')));
      }
    }

    final glyph = _Glyph(
      phase: phase,
      progress: progress,
      // Unknown size (no Content-Length yet) spins instead of sitting at 0.
      determinate: (item?.totalBytes ?? 0) > 0,
      size: showLabel ? 30 : diameter * 0.62,
    );

    final label = switch (phase) {
      _Phase.idle => 'Download',
      _Phase.pending => 'Waiting…',
      _Phase.running =>
        (item?.totalBytes ?? 0) > 0 ? '${(progress * 100).round()}%' : 'Starting…',
      _Phase.paused => 'Paused',
      _Phase.done => 'Downloaded',
    };
    final semantics = switch (phase) {
      _Phase.idle => 'Download',
      _Phase.done => 'Downloaded',
      _ => 'Cancel download, $label',
    };

    if (showLabel) {
      final color =
          phase == _Phase.done ? AppColors.accent : AppColors.textPrimary;
      return Semantics(
        button: true,
        label: semantics,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          focusColor: AppColors.accentSoft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(dimension: 30, child: Center(child: glyph)),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Text(
                    label,
                    key: ValueKey(label),
                    style: TextStyle(color: color, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: semantics,
      child: Material(
        color: background ?? Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          focusColor: AppColors.accentSoft,
          onTap: onTap,
          child: SizedBox.square(
            dimension: diameter,
            child: Center(child: glyph),
          ),
        ),
      ),
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.phase,
    required this.progress,
    required this.determinate,
    required this.size,
  });

  final _Phase phase;
  final double progress;
  final bool determinate;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget child = switch (phase) {
      _Phase.idle => Icon(
          Icons.download_rounded,
          key: const ValueKey('idle'),
          size: size * 0.8,
          color: AppColors.textPrimary,
        ),
      _Phase.done => Icon(
          Icons.download_done_rounded,
          key: const ValueKey('done'),
          size: size * 0.8,
          color: AppColors.accent,
        ),
      _ => SizedBox.square(
          key: const ValueKey('ring'),
          dimension: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Faint full track under the ring.
              CircularProgressIndicator(
                value: 1,
                strokeWidth: 2.4,
                color: Colors.white.withValues(alpha: 0.14),
              ),
              if (phase == _Phase.running && determinate)
                TweenAnimationBuilder<double>(
                  // The manager reports about once a second; ease between.
                  tween: Tween(end: progress),
                  duration: const Duration(milliseconds: 900),
                  builder: (_, v, __) => CircularProgressIndicator(
                    value: v,
                    strokeWidth: 2.4,
                    strokeCap: StrokeCap.round,
                    color: AppColors.accent,
                  ),
                )
              else if (phase == _Phase.paused)
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2.4,
                  color: AppColors.textSecondary,
                )
              else
                const CircularProgressIndicator(
                  strokeWidth: 2.4,
                  strokeCap: StrokeCap.round,
                  color: AppColors.accent,
                ),
              // The "stop" dot — tap target to cancel.
              Container(
                width: size * 0.3,
                height: size * 0.3,
                decoration: BoxDecoration(
                  color: phase == _Phase.paused
                      ? AppColors.textSecondary
                      : AppColors.accent,
                  borderRadius: BorderRadius.circular(size * 0.07),
                ),
              ),
            ],
          ),
        ),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(scale: anim, child: child),
      ),
      child: child,
    );
  }
}
