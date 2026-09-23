import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/content.dart';
import '../providers.dart';

/// Decides what is fit to *recommend* — Home rows, the carousel, and the
/// "More Movies" suggestions. Search and full category lists are never
/// filtered: anything hidden here is still one search away.
///
/// Panels pad their VOD lists with things that are not films: dated event
/// recordings ("26.09.2025 Friday Night SmackDown"), wrestling/fight shows,
/// items with no artwork, and items wearing a recycled poster that belongs
/// to something else (one image stamped on hundreds of entries).
class ContentFilter {
  ContentFilter._(this._recycledPosters);

  /// Built once per catalogue list.
  factory ContentFilter.fromPosters(Iterable<String?> posters) {
    final counts = <String, int>{};
    for (final p in posters) {
      final key = _norm(p);
      if (key != null) counts[key] = (counts[key] ?? 0) + 1;
    }
    return ContentFilter._({
      for (final e in counts.entries)
        if (e.value >= _recycledAfter) e.key,
    });
  }

  /// A poster on this many distinct entries is a placeholder, not artwork.
  static const _recycledAfter = 5;

  final Set<String> _recycledPosters;

  /// "26.09.2025", "2025-09-26", "26/9/25" anywhere in the title.
  static final _date = RegExp(
    r'\b(\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{4}[./-]\d{1,2}[./-]\d{1,2})\b',
  );

  static final _events = RegExp(
    r'\b(wwe|smack ?down|monday night raw|wwe raw|aew|ufc|nxt|'
    r'wrestle ?mania|wrestling|ppv|pay[- ]per[- ]view|dynamite|rampage|'
    r'friday night|saturday night main event|royal rumble|summerslam)\b',
    caseSensitive: false,
  );

  static String? _norm(String? url) {
    final u = url?.trim();
    if (u == null || u.isEmpty) return null;
    final l = u.toLowerCase();
    if (l == 'null' || l == 'n/a') return null;
    return l;
  }

  bool keep(String name, String? poster) {
    final p = _norm(poster);
    if (p == null) return false;
    if (_recycledPosters.contains(p)) return false;
    if (_date.hasMatch(name)) return false;
    if (_events.hasMatch(name)) return false;
    return true;
  }

  bool keepMovie(Movie m) => keep(m.name, m.poster);
  bool keepSeries(Series s) => keep(s.name, s.cover);
}

final movieFilterProvider = FutureProvider<ContentFilter>((ref) async {
  final movies = await ref.watch(moviesProvider('').future);
  return ContentFilter.fromPosters(movies.map((m) => m.poster));
});

final seriesFilterProvider = FutureProvider<ContentFilter>((ref) async {
  final series = await ref.watch(seriesProvider('').future);
  return ContentFilter.fromPosters(series.map((s) => s.cover));
});
