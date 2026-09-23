import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The round night-sky badge with a rocket in it, from the loading-screen
/// reference: twinkling stars, speed streaks falling past, and a red rocket
/// bobbing on a flickering flame.
///
/// Self-contained and wrapped in a RepaintBoundary so its 60fps animation
/// only repaints this circle, not the whole loading screen.
class RocketScene extends StatefulWidget {
  const RocketScene({super.key, required this.size});

  final double size;

  @override
  State<RocketScene> createState() => _RocketSceneState();
}

class _RocketSceneState extends State<RocketScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    // One long loop; the painter derives every motion from elapsed time so
    // nothing visibly "resets" when it wraps.
    duration: const Duration(seconds: 12),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _clock.stop();
      _clock.value = 0.1;
    } else if (!_clock.isAnimating) {
      _clock.repeat();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(painter: _RocketPainter(_clock)),
      ),
    );
  }
}

class _Star {
  const _Star(this.x, this.y, this.r, this.phase, this.sparkle);
  final double x, y, r, phase;
  final bool sparkle;
}

class _Streak {
  const _Streak(this.x, this.len, this.speed, this.offset);
  final double x, len, speed, offset;
}

class _RocketPainter extends CustomPainter {
  _RocketPainter(this.clock) : super(repaint: clock);

  final Animation<double> clock;

  static final _stars = () {
    final rnd = math.Random(7);
    return List.generate(46, (i) {
      return _Star(
        rnd.nextDouble(),
        rnd.nextDouble(),
        0.6 + rnd.nextDouble() * 1.3,
        rnd.nextDouble() * math.pi * 2,
        i % 5 == 0,
      );
    });
  }();

  static final _streaks = () {
    final rnd = math.Random(3);
    return List.generate(11, (_) {
      return _Streak(
        0.12 + rnd.nextDouble() * 0.76,
        0.05 + rnd.nextDouble() * 0.08,
        0.55 + rnd.nextDouble() * 0.6,
        rnd.nextDouble(),
      );
    });
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.width;
    final c = Offset(d / 2, d / 2);
    // Seconds since the loop started (12s loop).
    final t = clock.value * 12;

    // Sky.
    canvas.drawCircle(c, d / 2, Paint()..color = const Color(0xFF0C0C0D));
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: d / 2)));

    // Stars drift slowly downwards (the rocket is climbing) and twinkle.
    final starPaint = Paint();
    for (final s in _stars) {
      final y = ((s.y + t * 0.035) % 1.0) * d;
      final x = s.x * d;
      final twinkle = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 2.2 + s.phase));
      starPaint.color = Colors.white.withValues(alpha: 0.85 * twinkle);
      if (s.sparkle) {
        _sparkle(canvas, Offset(x, y), s.r * 2.6, starPaint);
      } else {
        canvas.drawCircle(Offset(x, y), s.r, starPaint);
      }
    }

    // Speed streaks.
    final streakPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = d * 0.011
      ..strokeCap = StrokeCap.round;
    for (final s in _streaks) {
      final travel = (s.offset + t * s.speed) % 1.0;
      final y = -s.len * d + travel * (d * (1 + s.len));
      canvas.drawLine(
        Offset(s.x * d, y),
        Offset(s.x * d, y + s.len * d),
        streakPaint,
      );
    }
    canvas.restore();

    // Rocket: gentle bob and sway.
    final bob = math.sin(t * math.pi * 1.3) * d * 0.018;
    final sway = math.sin(t * math.pi * 0.9) * 0.07;
    canvas.save();
    canvas.translate(c.dx, c.dy + bob);
    canvas.rotate(sway);
    _rocket(canvas, d, t);
    canvas.restore();
  }

  void _sparkle(Canvas canvas, Offset p, double r, Paint paint) {
    final path = Path()
      ..moveTo(p.dx, p.dy - r)
      ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
      ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
      ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
      ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _rocket(Canvas canvas, double d, double t) {
    final w = d * 0.2; // body width
    final h = d * 0.36; // body height
    final top = -h * 0.55;
    final bottom = h * 0.38;

    // Flame (behind the body), flickering length.
    final flicker = 0.75 + 0.25 * math.sin(t * 38) * math.sin(t * 23 + 1);
    final flameLen = h * (0.26 + 0.1 * flicker);
    final flame = Path()
      ..moveTo(-w * 0.2, bottom - h * 0.02)
      ..quadraticBezierTo(-w * 0.16, bottom + flameLen * 0.6, 0, bottom + flameLen)
      ..quadraticBezierTo(w * 0.16, bottom + flameLen * 0.6, w * 0.2, bottom - h * 0.02)
      ..close();
    canvas.drawPath(
      flame,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0xFFFFE27A), Color(0xFFFFB02E), Color(0xFFFF7A1A)],
        ).createShader(Rect.fromLTWH(-w * 0.2, bottom, w * 0.4, flameLen)),
    );

    // Fins.
    final finPaint = Paint()..color = const Color(0xFFF4F4F4);
    for (final side in const [-1.0, 1.0]) {
      final fin = Path()
        ..moveTo(side * w * 0.42, h * 0.02)
        ..quadraticBezierTo(side * w * 0.95, h * 0.18, side * w * 0.82, bottom + h * 0.1)
        ..quadraticBezierTo(side * w * 0.6, bottom - h * 0.06, side * w * 0.3, bottom - h * 0.02)
        ..close();
      canvas.drawPath(fin, finPaint);
    }

    // Body.
    final body = Path()
      ..moveTo(0, top)
      ..cubicTo(w * 0.42, top + h * 0.2, w * 0.58, h * 0.02, w * 0.36, bottom)
      ..lineTo(-w * 0.36, bottom)
      ..cubicTo(-w * 0.58, h * 0.02, -w * 0.42, top + h * 0.2, 0, top)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFF3B45), Color(0xFFE51F2A), Color(0xFFB9141D)],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromLTWH(-w * 0.55, top, w * 1.1, h)),
    );

    // Centre fin, edge-on.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(0, bottom - h * 0.02), width: w * 0.1, height: h * 0.2),
        Radius.circular(w * 0.05),
      ),
      finPaint,
    );

    // Window.
    final windowC = Offset(0, top + h * 0.38);
    canvas.drawCircle(windowC, w * 0.22, Paint()..color = const Color(0xFF1B1B1D));
    canvas.drawCircle(windowC, w * 0.16, Paint()..color = Colors.white);
    canvas.drawCircle(
      windowC.translate(-w * 0.05, -w * 0.05),
      w * 0.05,
      Paint()..color = const Color(0xFFDDE7F0),
    );
  }

  @override
  bool shouldRepaint(_RocketPainter old) => old.clock != clock;
}
