import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/routes.dart';
import '../../core/errors/app_error.dart';
import '../../core/theme/app_colors.dart';
import 'catalog_load_controller.dart';
import 'rocket_scene.dart';

/// "Please wait while we load your Xtream data" — shown after adding an
/// account, after switching accounts, and on every cold start with a saved
/// session. It is not decoration: [CatalogLoadController] really downloads
/// and caches movies, series and live channels while this is on screen, and
/// the bar and the highlighted row reflect that work as it happens.
class CatalogLoadingScreen extends ConsumerStatefulWidget {
  const CatalogLoadingScreen({super.key, required this.next});

  /// Where to go once everything is loaded.
  final String next;

  @override
  ConsumerState<CatalogLoadingScreen> createState() =>
      _CatalogLoadingScreenState();
}

class _CatalogLoadingScreenState extends ConsumerState<CatalogLoadingScreen> {
  static const _bg = Color(0xFF1C1C1E);

  static const _labels = {
    LoadStage.movies: 'Movies Without Bounds – Endless Entertainment Anywhere!',
    LoadStage.series: 'Series Unleashed: Dive into a World of Endless Episodes.',
    LoadStage.live: 'Live Channels Redefined: Experience the Action as it Happens',
    LoadStage.downloads: 'Download Without Limits – Take Your Favorites Anywhere!',
    LoadStage.library: 'Your Library, Your Rules – Stream Your Way!',
  };

  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(catalogLoadProvider.notifier).run();
    });
  }

  void _continue() {
    if (_leaving || !mounted) return;
    _leaving = true;
    context.go(widget.next);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(catalogLoadProvider, (prev, next) {
      if (next.finished && !(prev?.finished ?? false)) {
        // Let the full bar register for a beat before moving on.
        Timer(const Duration(milliseconds: 450), _continue);
      }
    });
    final state = ref.watch(catalogLoadProvider);
    final signedOut = state.error?.kind == AppErrorKind.authentication;
    final size = MediaQuery.sizeOf(context);
    final contentWidth = math.min(size.width - 40, 440.0);

    return PopScope(
      // Backing out mid-load would drop the user on a half-loaded Home.
      canPop: state.error != null,
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            const Positioned.fill(child: _Decorations()),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: SizedBox(
                    width: contentWidth,
                    child: Column(
                      children: [
                        RocketScene(size: math.min(size.width * 0.54, 230)),
                        const SizedBox(height: 28),
                        _MessageBox(
                          text: state.error == null
                              ? 'Please wait while we load your Xtream data 🍿'
                              : state.error!.message,
                          isError: state.error != null,
                        ),
                        const SizedBox(height: 22),
                        _ProgressBar(
                          value: state.progress,
                          width: contentWidth * 0.78,
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: contentWidth * 0.9,
                          child: Column(
                            children: [
                              for (final stage in LoadStage.values)
                                _StageRow(
                                  label: _labels[stage]!,
                                  stage: state.of(stage),
                                  current: state.error == null &&
                                      state.current == stage,
                                  showDivider: stage != LoadStage.values.last,
                                ),
                            ],
                          ),
                        ),
                        if (state.error != null) ...[
                          const SizedBox(height: 24),
                          _ErrorActions(
                            onRetry: () =>
                                ref.read(catalogLoadProvider.notifier).run(),
                            onSkip: signedOut
                                ? () => context.go(Routes.login)
                                : _continue,
                            skipLabel:
                                signedOut ? 'Add account' : 'Continue anyway',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF171718),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError ? AppColors.accent : const Color(0xFF3A3A3C),
        ),
      ),
      // One line, as in the reference: scale down rather than wrap on narrow
      // phones. Error messages are longer and may wrap.
      child: isError
          ? Text(text, textAlign: TextAlign.center, style: _style)
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(text, maxLines: 1, style: _style),
            ),
    );
  }

  static const _style = TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          height: 1.3,
        );
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.width});

  final double value;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      value: '${(value * 100).round()}%',
      child: Container(
        width: width,
        height: 5,
        decoration: BoxDecoration(
          color: const Color(0xFF0E0E0F),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          // Ease between the ~30fps progress updates so the bar glides.
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          builder: (context, v, _) => FractionallySizedBox(
            widthFactor: v,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.label,
    required this.stage,
    required this.current,
    required this.showDivider,
  });

  final String label;
  final StageState stage;
  final bool current;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final done = stage.isDone;
    final failed = stage.status == StageStatus.failed;
    final color = current
        ? Colors.white
        : done
            ? const Color(0xFF8E8E93)
            : const Color(0xFF3E3E41);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: showDivider
            ? const Border(bottom: BorderSide(color: Color(0xFF3A3A3C)))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 3.5,
            height: current ? 26 : 0,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: TextStyle(
                color: failed ? AppColors.accent : color,
                fontSize: 15,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
              child: Text(label),
            ),
          ),
          if (done) ...[
            const SizedBox(width: 10),
            if (stage.count != null)
              Text(
                NumberFormat.decimalPattern().format(stage.count),
                style: const TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(width: 6),
            const Icon(Icons.check_rounded, size: 16, color: Color(0xFF8E8E93)),
          ],
        ],
      ),
    );
  }
}

class _ErrorActions extends StatelessWidget {
  const _ErrorActions({
    required this.onRetry,
    required this.onSkip,
    required this.skipLabel,
  });

  final VoidCallback onRetry;
  final VoidCallback onSkip;
  final String skipLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
        const SizedBox(width: 12),
        TextButton(onPressed: onSkip, child: Text(skipLabel)),
      ],
    );
  }
}

/// Faint rings and four-point stars scattered on the background.
class _Decorations extends StatelessWidget {
  const _Decorations();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(child: CustomPaint(painter: _DecorPainter()));
  }
}

class _DecorPainter extends CustomPainter {
  const _DecorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const c = Color(0xFF38383B);
    final ring = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;
    final fill = Paint()..color = c;
    final w = size.width, h = size.height;

    canvas.drawCircle(Offset(w * 0.15, h * 0.05), 8, ring);
    canvas.drawCircle(Offset(w * 0.085, h * 0.315), 11, ring);
    canvas.drawCircle(Offset(w * 0.98, h * 0.21), 8, ring);

    void star(Offset p, double r) {
      final path = Path()
        ..moveTo(p.dx, p.dy - r)
        ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
        ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
        ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
        ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r)
        ..close();
      canvas.drawPath(path, fill);
    }

    star(Offset(w * 0.925, h * 0.05), 13);
    star(Offset(w * 0.025, h * 0.185), 8);
    star(Offset(w * 0.82, h * 0.353), 9);
  }

  @override
  bool shouldRepaint(_DecorPainter old) => false;
}
