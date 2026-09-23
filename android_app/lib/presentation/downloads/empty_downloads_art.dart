import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Flat empty-state illustration for the Downloads tab: a figure beside a
/// laptop showing a blocked play button, a film strip with a download badge,
/// and a speech bubble.
///
/// Drawn with [CustomPainter] rather than shipped as an asset — it adds no
/// APK weight, scales cleanly, and takes its accent from the theme. It is
/// original artwork in the reference's flat style, not a copy of it.
class EmptyDownloadsArt extends StatelessWidget {
  const EmptyDownloadsArt({super.key, this.size = 220});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 0.85,
      child: CustomPaint(painter: _EmptyDownloadsPainter()),
    );
  }
}

class _EmptyDownloadsPainter extends CustomPainter {
  // Muted greys so the crimson accents carry the eye.
  static const _dark = Color(0xFF2A2A2E);
  static const _mid = Color(0xFF3A3A40);
  static const _light = Color(0xFF4A4A52);
  static const _skin = Color(0xFFE8B48C);
  static const _hair = Color(0xFF17171A);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // ---- Desk line -------------------------------------------------------
    fill.color = _light;
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.06, h * 0.80, w * 0.86, h * 0.815, const Radius.circular(2)),
      fill,
    );

    // ---- Film strip with download badge (upper left) ---------------------
    final stripRect = RRect.fromLTRBR(
        w * 0.18, h * 0.14, w * 0.50, h * 0.36, const Radius.circular(3));
    fill.color = _dark;
    canvas.drawRRect(stripRect, fill);
    // Sprocket holes.
    fill.color = _light;
    for (var i = 0; i < 5; i++) {
      final x = w * (0.205 + i * 0.058);
      canvas.drawRect(Rect.fromLTWH(x, h * 0.155, w * 0.022, h * 0.022), fill);
      canvas.drawRect(Rect.fromLTWH(x, h * 0.325, w * 0.022, h * 0.022), fill);
    }
    // Download badge.
    final badgeCentre = Offset(w * 0.505, h * 0.345);
    fill.color = AppColors.accent;
    canvas.drawCircle(badgeCentre, w * 0.055, fill);
    stroke
      ..color = Colors.white
      ..strokeWidth = 2.2;
    canvas.drawLine(
      badgeCentre.translate(0, -w * 0.022),
      badgeCentre.translate(0, w * 0.018),
      stroke,
    );
    canvas.drawLine(
      badgeCentre.translate(-w * 0.018, 0),
      badgeCentre.translate(0, w * 0.018),
      stroke,
    );
    canvas.drawLine(
      badgeCentre.translate(w * 0.018, 0),
      badgeCentre.translate(0, w * 0.018),
      stroke,
    );

    // ---- Small card behind the laptop ------------------------------------
    fill.color = _dark;
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.06, h * 0.44, w * 0.32, h * 0.62,
          const Radius.circular(4)),
      fill,
    );
    fill.color = _light;
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.10, h * 0.48, w * 0.28, h * 0.50,
          const Radius.circular(2)),
      fill,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.10, h * 0.53, w * 0.24, h * 0.55,
          const Radius.circular(2)),
      fill,
    );

    // ---- Laptop / screen -------------------------------------------------
    final screen = RRect.fromLTRBR(
        w * 0.16, h * 0.50, w * 0.66, h * 0.80, const Radius.circular(5));
    fill.color = _mid;
    canvas.drawRRect(screen, fill);
    // Inner panel.
    final panel = RRect.fromLTRBR(
        w * 0.30, h * 0.56, w * 0.60, h * 0.74, const Radius.circular(3));
    fill.color = _light;
    canvas.drawRRect(panel, fill);
    // Window dots.
    fill.color = _light;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
          Offset(w * (0.545 + i * 0.028), h * 0.535), w * 0.008, fill);
    }
    // Play triangle on the panel.
    fill.color = const Color(0xFF6B6B74);
    final play = Path()
      ..moveTo(w * 0.425, h * 0.615)
      ..lineTo(w * 0.425, h * 0.685)
      ..lineTo(w * 0.485, h * 0.650)
      ..close();
    canvas.drawPath(play, fill);

    // "No play" circle-slash badge.
    final noPlay = Offset(w * 0.335, h * 0.645);
    fill.color = Colors.white;
    canvas.drawCircle(noPlay, w * 0.052, fill);
    stroke
      ..color = AppColors.accent
      ..strokeWidth = 3.4;
    canvas.drawCircle(noPlay, w * 0.038, stroke);
    canvas.drawLine(
      noPlay.translate(-w * 0.027, -w * 0.027),
      noPlay.translate(w * 0.027, w * 0.027),
      stroke,
    );

    // ---- Figure ----------------------------------------------------------
    // Torso.
    fill.color = _dark;
    final torso = Path()
      ..moveTo(w * 0.62, h * 0.80)
      ..lineTo(w * 0.655, h * 0.56)
      ..quadraticBezierTo(w * 0.755, h * 0.50, w * 0.855, h * 0.56)
      ..lineTo(w * 0.89, h * 0.80)
      ..close();
    canvas.drawPath(torso, fill);
    // Collar.
    fill.color = _mid;
    final collar = Path()
      ..moveTo(w * 0.715, h * 0.525)
      ..lineTo(w * 0.755, h * 0.585)
      ..lineTo(w * 0.795, h * 0.525)
      ..close();
    canvas.drawPath(collar, fill);
    // Arm reaching to the laptop.
    fill.color = _dark;
    final arm = Path()
      ..moveTo(w * 0.655, h * 0.58)
      ..quadraticBezierTo(w * 0.585, h * 0.66, w * 0.605, h * 0.755)
      ..lineTo(w * 0.665, h * 0.755)
      ..quadraticBezierTo(w * 0.655, h * 0.665, w * 0.700, h * 0.605)
      ..close();
    canvas.drawPath(arm, fill);
    // Hand.
    fill.color = _skin;
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.595, h * 0.745, w * 0.675, h * 0.790,
          const Radius.circular(8)),
      fill,
    );
    // Neck + head.
    fill.color = _skin;
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.735, h * 0.455, w * 0.780, h * 0.530,
          const Radius.circular(6)),
      fill,
    );
    canvas.drawCircle(Offset(w * 0.757, h * 0.395), w * 0.072, fill);
    // Hair.
    fill.color = _hair;
    final hair = Path()
      ..addArc(
        Rect.fromCircle(center: Offset(w * 0.757, h * 0.395), radius: w * 0.075),
        3.34,
        3.6,
      );
    canvas.drawPath(hair, fill);
    // Eye.
    fill.color = _hair;
    canvas.drawCircle(Offset(w * 0.790, h * 0.400), w * 0.007, fill);

    // ---- Speech bubble ---------------------------------------------------
    fill.color = Colors.white;
    canvas.drawCircle(Offset(w * 0.900, h * 0.285), w * 0.070, fill);
    final tail = Path()
      ..moveTo(w * 0.865, h * 0.335)
      ..lineTo(w * 0.845, h * 0.385)
      ..lineTo(w * 0.895, h * 0.350)
      ..close();
    canvas.drawPath(tail, fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
