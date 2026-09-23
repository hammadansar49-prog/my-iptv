/// Route names in one place so no string literals are scattered through the
/// app (spec §52, §66).
abstract final class Routes {
  static const splash = '/';
  /// Pre-login setup screen (source picker).
  static const login = '/login';

  /// The real Xtream Codes credential form.
  static const xtreamLogin = '/login/xtream';

  /// "Please wait while we load your Xtream data" — really downloads the
  /// catalogue. `extra` is the route to continue to (defaults to Home).
  static const catalogLoading = '/loading';

  /// Saved Xtream accounts + switcher.
  static const accounts = '/accounts';
  static const license = '/license';
  static const plans = '/plans';

  /// Shell with the floating bottom bar: Home / EPG / Downloads / Profile.
  static const home = '/home';
  static const epg = '/epg';
  static const downloads = '/downloads';
  static const profile = '/profile';

  static const liveTv = '/live';
  static const movies = '/movies';
  static const series = '/series';
  static const movieDetail = '/movies/detail';
  static const seriesDetail = '/series/detail';
  static const player = '/player';
  static const search = '/search';
  static const favorites = '/favorites';
  static const settings = '/settings';
  static const security = '/settings/security';

  /// PIN entry shown at startup when app-lock is on. `extra` carries the
  /// route to continue to once unlocked.
  static const lock = '/lock';
}
