import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models/content.dart';
import '../presentation/auth/login_screen.dart';
import '../presentation/auth/splash_screen.dart';
import '../presentation/live_tv/live_tv_screen.dart';
import '../presentation/movies/movie_detail_screen.dart';
import '../presentation/movies/movies_screen.dart';
import '../presentation/player/player_screen.dart';
import '../presentation/series/series_detail_screen.dart';
import '../presentation/settings/settings_screen.dart';
import '../presentation/series/series_screen.dart';
import '../presentation/shell/home_shell.dart';
import '../services/player/playback_request.dart';
import 'routes.dart';

/// Declarative routing with a predictable back stack (spec §52).
///
/// The splash decides where to go; it is not a redirect guard, because a
/// redirect that runs on every navigation would re-check the session far more
/// often than needed and is a classic source of navigation loops.
GoRouter buildRouter(Ref ref) {
  return GoRouter(
    initialLocation: Routes.splash,
    routes: [
      GoRoute(
        path: Routes.splash,
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const HomeShell(),
      ),
      GoRoute(
        path: Routes.liveTv,
        builder: (context, state) => LiveTvScreen(
          // `extra` is the channel to start on; arriving with nothing just
          // opens the screen idle rather than crashing.
          initialChannel:
              state.extra is LiveChannel ? state.extra as LiveChannel : null,
        ),
      ),
      GoRoute(
        path: Routes.movies,
        builder: (context, state) => const MoviesScreen(),
      ),
      GoRoute(
        path: Routes.movieDetail,
        builder: (context, state) {
          final movie = state.extra;
          if (movie is! Movie) {
            return const Scaffold(
              body: Center(child: Text('That movie could not be opened.')),
            );
          }
          return MovieDetailScreen(movie: movie);
        },
      ),
      GoRoute(
        path: Routes.series,
        builder: (context, state) => const SeriesScreen(),
      ),
      GoRoute(
        path: Routes.seriesDetail,
        builder: (context, state) {
          final series = state.extra;
          if (series is! Series) {
            return const Scaffold(
              body: Center(child: Text('That series could not be opened.')),
            );
          }
          return SeriesDetailScreen(series: series);
        },
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.player,
        builder: (context, state) {
          final request = state.extra;
          if (request is! PlaybackRequest) {
            // Arriving here without something to play is a bug, not a crash.
            return const Scaffold(
              body: Center(child: Text('Nothing to play.')),
            );
          }
          return PlayerScreen(request: request);
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'That screen could not be opened.',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}
