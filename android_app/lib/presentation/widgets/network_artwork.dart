import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Every poster and channel logo in the app goes through here.
///
/// Spec §48: cached, lazily loaded, decoded at the size actually drawn, with
/// a placeholder and an error fallback. Decoding a 1000px poster into a 120px
/// card is the fastest way to blow up memory on a phone (spec §46), so
/// `memCacheWidth` is always set from the layout width.
class NetworkArtwork extends StatelessWidget {
  const NetworkArtwork({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.fallbackIcon = Icons.movie_outlined,
    this.fallbackLabel,
  });

  final String? url;
  final double width;
  final double height;
  final BorderRadius? borderRadius;
  final BoxFit fit;
  final IconData fallbackIcon;
  final String? fallbackLabel;

  bool get _usable {
    final u = url?.trim();
    if (u == null || u.isEmpty) return false;
    // Panels frequently ship "null", "N/A" or a bare path as the logo.
    final lower = u.toLowerCase();
    if (lower == 'null' || lower == 'n/a') return false;
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(Radii.md);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget content;
    if (!_usable) {
      content = _Fallback(
        icon: fallbackIcon,
        label: fallbackLabel,
        width: width,
        height: height,
      );
    } else {
      content = CachedNetworkImage(
        imageUrl: url!.trim(),
        width: width,
        height: height,
        fit: fit,
        // Decode no larger than needed for this box.
        memCacheWidth: (width * dpr).round().clamp(48, 1080),
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (context, _) => Container(
          width: width,
          height: height,
          color: AppColors.surfaceHigh,
        ),
        errorWidget: (context, _, __) => _Fallback(
          icon: fallbackIcon,
          label: fallbackLabel,
          width: width,
          height: height,
        ),
      );
    }

    return ClipRRect(borderRadius: radius, child: content);
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({
    required this.icon,
    required this.label,
    required this.width,
    required this.height,
  });

  final IconData icon;
  final String? label;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: AppColors.surfaceHigh,
      alignment: Alignment.center,
      child: label != null && label!.isNotEmpty
          ? Padding(
              padding: const EdgeInsets.all(Insets.xs),
              child: Text(
                label!.characters.take(2).toString().toUpperCase(),
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: (height * 0.34).clamp(10, 22),
                ),
              ),
            )
          : Icon(
              icon,
              color: AppColors.textTertiary,
              size: (height * 0.36).clamp(16, 40),
            ),
    );
  }
}
