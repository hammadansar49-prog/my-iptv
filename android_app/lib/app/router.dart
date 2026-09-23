import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models/content.dart';
import '../presentation/auth/accounts_screen.dart';
import '../presentation/auth/login_screen.dart';
import '../presentation/auth/setup_screen.dart';
import '../presentation/auth/splash_screen.dart';
import '../presentation/custom_sources/channel_edit_screen.dart';
import '../presentation/custom_sources/custom_models.dart';
import '../presentation/custom_sources/my_channels_screen.dart';
import '../presentation/custom_sources/playlist_add_screen.dart';
import '../presentation/custom_sources/playlist_screen.dart';
import '../presentation/custom_sources/playlists_screen.dart';
import '../presentation/favorites/favorites_screen.dart';
import '../presentation/live_tv/live_tv_screen.dart';
import '../presentation/license/license_screen.dart';
import '../presentation/license/plans_screen.dart';
import '../presentation/loading/catalog_loading_screen.dart';
import '../presentation/movies/movie_detail_screen.dart';
import '../presentation/movies/movies_screen.dart';
import '../presentation/player/player_screen.dart';
import '../presentation/profile/about_screen.dart';
import '../presentation/security/lock_screen.dart';
import '../presentation/security/security_screen.dart';
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
      // Pre-login entry: the source picker.
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const SetupScreen(),
      ),
      // The real Xtream credential form.
      GoRoute(
        path: Routes.xtreamLogin,
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: Routes.catalogLoading,
        builder: (context, state) => CatalogLoadingScreen(
          next: state.extra is String ? state.extra as String : Routes.home,
        ),
      ),
      GoRoute(
        path: Routes.license,
        builder: (context, state) => LicenseScreen(
          next: state.extra is String ? state.extra as String : Routes.home,
        ),
      ),
      GoRoute(
        path: Routes.plans,
        builder: (context, state) => const PlansScreen(),
      ),
      GoRoute(
        path: Routes.accounts,
        builder: (context, state) => const AccountsScreen(),
      ),
      GoRoute(
        path: Routes.customChannels,
        builder: (context, state) => const MyChannelsScreen(),
      ),
      GoRoute(
        path: Routes.customChannelEdit,
        builder: (context, state) => ChannelEditScreen(
          existing:
              state.extra is CustomChannel ? state.extra as CustomChannel : null,
        ),
      ),
      GoRoute(
        path: Routes.customPlaylists,
        builder: (context, state) => const PlaylistsScreen(),
      ),
      GoRoute(
        path: Routes.customPlaylistAdd,
        builder: (context, state) => const PlaylistAddScreen(),
      ),
      GoRoute(
        path: Routes.customPlaylist,
        // Without an id (e.g. a cold restore) fall back to the list.
        builder: (context, state) => state.extra is String
            ? PlaylistScreen(playlistId: state.extra as String)
            : const PlaylistsScreen(),
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
        path: Routes.favorites,
        builder: (context, state) => const FavoritesScreen(),
      ),
      GoRoute(
        path: Routes.settings,
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.about,
        builder: (context, state) => const AboutScreen(),
      ),
      GoRoute(
        path: Routes.security,
        builder: (context, state) => const SecurityScreen(),
      ),
      GoRoute(
        path: Routes.lock,
        builder: (context, state) => LockScreen(
          target: state.extra is String ? state.extra as String : Routes.home,
        ),
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
