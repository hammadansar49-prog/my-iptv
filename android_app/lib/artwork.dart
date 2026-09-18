import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'theme.dart';

/// A large share of this provider's catalog (close to 30,000 movies) links
/// artwork as a bare TMDB size folder — ".../t/p/w600_and_h900_bestv2" with no
/// image in it. Those can only ever fail, so they get the title card right
/// away instead of a request each.
String usableArtwork(String? url) {
  if (url == null || url.isEmpty) return '';
  final path = url.split(RegExp(r'[?#]')).first.replaceAll(RegExp(r'/+$'), '');
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(path)) return '';
  if (RegExp(r'^https?://[^/]+$', caseSensitive: false).hasMatch(path)) return '';
  final slash = path.lastIndexOf('/');
  final last = path.substring(slash + 1);
  final parent = path.substring(0, slash);
  if (RegExp(r'/t/p$', caseSensitive: false).hasMatch(parent) &&
      RegExp(r'^(w\d+|h\d+|original)(_and_h\d+)?(_bestv2)?$', caseSensitive: false).hasMatch(last)) {
    return '';
  }
  return url;
}

/// TMDB serves every poster in several sizes and providers link the 600px
/// one — five times the bytes a phone grid cell can show. Ask for the size
/// closest to what's displayed.
String sizedArtwork(String url, int logicalWidth) {
  final m = RegExp(r'^(https?://image\.tmdb\.org/t/p/)[^/]+(/.+)$', caseSensitive: false).firstMatch(url);
  if (m == null) return url;
  final w = logicalWidth * 2; // ~2x density
  final size = w <= 185 ? 'w185' : w <= 342 ? 'w342' : w <= 500 ? 'w500' : 'w780';
  return '${m.group(1)}$size${m.group(2)}';
}

/// Poster / logo image: downloaded once into the disk cache, decoded at the
/// size it is drawn (not the full 600x900), and only built for cells that are
/// actually on screen — grids and lists build their children lazily.
class Artwork extends StatelessWidget {
  final String? url;
  final String title;
  final double width;
  final BoxFit fit;
  final double radius;
  final IconData? placeholderIcon;

  const Artwork({
    super.key,
    required this.url,
    this.title = '',
    required this.width,
    this.fit = BoxFit.cover,
    this.radius = 0,
    this.placeholderIcon,
  });

  @override
  Widget build(BuildContext context) {
    final src = usableArtwork(url);
    final mq = MediaQuery.of(context);
    final ratio = mq.size.width > 0 ? mq.devicePixelRatio : 2.0;
    final child = src.isEmpty
        ? _placeholder()
        : CachedNetworkImage(
            imageUrl: sizedArtwork(src, width.round()),
            fit: fit,
            memCacheWidth: (width * ratio).round(),
            fadeInDuration: const Duration(milliseconds: 150),
            placeholder: (_, __) => Container(color: AppColors.bg3),
            errorWidget: (_, __, ___) => _placeholder(),
            httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
          );
    if (radius <= 0) return child;
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }

  Widget _placeholder() => Container(
        color: AppColors.bg3,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(6),
        child: placeholderIcon != null
            ? Icon(placeholderIcon, color: AppColors.textDim)
            : Text(
                title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: AppColors.textDim),
              ),
      );
}
