/// Values lifted straight out of the PC app so the two behave identically.
/// Every one of these is documented in android_app/AUDIT.md — do not "tidy"
/// them without reading that first.
abstract final class Api {
  /// main.js `fetchText`.
  static const metadataUserAgent = 'IPTVPlayer/1.0';

  /// downloads.js — some panels behave differently per UA; keep it.
  static const downloadUserAgent =
      'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100';

  static const connectTimeout = Duration(seconds: 20);
  static const metadataTimeout = Duration(seconds: 45);
  static const maxRedirects = 5;

  /// 80 MB safety cap on a metadata response (main.js MAX_BYTES).
  static const maxResponseBytes = 80 * 1024 * 1024;
}

abstract final class Playback {
  /// A dead live channel must fail in ~11-12s, not 20-30s (CLAUDE.md).
  static const liveOpenTimeout = Duration(seconds: 12);
  static const liveStallTimeout = Duration(seconds: 12);
  static const liveMaxRetries = 3;

  /// The one-connection account needs a moment to notice the previous socket
  /// closed before it will accept a new one (CLAUDE.md).
  static const providerHandoverGap = Duration(milliseconds: 700);

  static const seekStep = Duration(seconds: 10);

  /// History is written at most this often while playing (spec §31).
  static const historyThrottle = Duration(seconds: 10);

  /// Below this, resuming is pointless; above [resumeMaxFraction] of the
  /// duration the item counts as finished. Mirrors updateHistoryBadges().
  static const resumeMinSeconds = 5;
  static const resumeMaxFraction = 0.95;

  static const controlsAutoHide = Duration(seconds: 4);
}

abstract final class Downloads {
  static const retryableStatus = <int>{
    401, 403, 408, 429, 458, 500, 502, 503, 504, 509,
  };
  static const maxRetries = 10;
  static const maxRedirects = 6;
  static const socketTimeout = Duration(seconds: 30);
  static const maxBackoff = Duration(seconds: 15);

  /// Downloads pick back up this long after playback stops — the provider
  /// needs the gap (downloads.js playbackEnded).
  static const resumeAfterPlayback = Duration(milliseconds: 2500);
}

abstract final class Limits {
  /// src/renderer.js HISTORY_LIMIT.
  static const historyEntries = 60;

  /// How long a fetched catalogue stays fresh before a background refresh.
  static const catalogTtl = Duration(hours: 6);

  /// EPG is recomputed locally; only the fetch is cached.
  static const epgTtl = Duration(minutes: 30);
}

abstract final class Licensing {
  /// Public client-safe config, exactly as main.js ships it: access control
  /// lives in the RTDB security rules, not in keeping this URL secret.
  /// Overridable at build time with --dart-define (spec §51).
  static const rtdbUrl = String.fromEnvironment(
    'MYIPTV_RTDB_URL',
    defaultValue: 'https://theottdeals-reviews-default-rtdb.firebaseio.com',
  );

  /// main.js revalidateLicenseInBackground().
  static const revalidateInterval = Duration(days: 1);

  /// src/renderer.js armLicenseWatch().
  static const localPollInterval = Duration(minutes: 30);
}
