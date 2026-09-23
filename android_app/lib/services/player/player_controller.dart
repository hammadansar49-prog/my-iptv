import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_error.dart';
import '../../core/network/connection_guard.dart';
import '../../core/utils/logger.dart';
import 'playback_request.dart';

enum PlaybackPhase { idle, opening, buffering, playing, paused, ended, failed }

@immutable
class PlayerState {
  const PlayerState({
    this.phase = PlaybackPhase.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.request,
    this.error,
    this.retryAttempt = 0,
  });

  final PlaybackPhase phase;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final PlaybackRequest? request;
  final AppError? error;
  final int retryAttempt;

  bool get isPlaying => phase == PlaybackPhase.playing;
  bool get isLive => request?.isLive ?? false;
  bool get hasMedia => request != null;

  /// Live streams must not show VOD progress controls (spec §23).
  bool get showsProgressBar => !isLive && duration > Duration.zero;

  PlayerState copyWith({
    PlaybackPhase? phase,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    PlaybackRequest? request,
    AppError? error,
    bool clearError = false,
    int? retryAttempt,
  }) =>
      PlayerState(
        phase: phase ?? this.phase,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        buffered: buffered ?? this.buffered,
        request: request ?? this.request,
        error: clearError ? null : (error ?? this.error),
        retryAttempt: retryAttempt ?? this.retryAttempt,
      );
}

/// Wraps exactly ONE media_kit [Player] for the lifetime of the screen that
/// owns it.
///
/// Locked decisions carried over from real device testing (CLAUDE.md):
///  * media_kit (libmpv), not video_player/ExoPlayer — it decodes MKV/HEVC/
///    AC-3 that Android's own decoders reject outright.
///  * `hwdec: 'no'` — hardware decoding produced a black frame with audio
///    still playing on a real device, not just an emulator.
///  * The same Player instance is reused when switching live channels, so
///    the inline YouTube-style Live TV screen never reloads the view.
///
/// Spec §21: rapid ±10 presses must not spawn player instances or overlapping
/// seeks — [seekBy] coalesces into a single pending target.
class PlayerController extends ChangeNotifier {
  PlayerController({required ConnectionGuard guard}) : _guard = guard;

  static const _tag = 'PlayerController';

  /// The one controller allowed to be playing, app-wide. A new playback
  /// stops the previous owner outright — audio and provider connection —
  /// rather than queueing behind it. Without this, a player that outlived
  /// its screen (a double-tapped Play pushing two player routes, say) kept
  /// playing sound after Back and held the account's single connection, so
  /// nothing else would start.
  static PlayerController? _active;

  /// Stop whatever is playing app-wide (sound + provider connection). Used
  /// when the user leaves a screen that keeps its player alive, e.g. the
  /// EPG tab, which the shell's IndexedStack never disposes.
  static Future<void> stopActive() async => _active?.stop();

  final ConnectionGuard _guard;

  Player? _player;
  VideoController? _videoController;
  ProviderLease? _lease;

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _stallWatchdog;
  Timer? _retryTimer;

  PlayerState _state = const PlayerState();
  PlayerState get state => _state;

  VideoController? get videoController => _videoController;

  /// The picture's real display aspect (width/height after pixel aspect),
  /// from libmpv. Null until the first frame's parameters arrive. SD IPTV
  /// streams are often 720x576 with non-square pixels; sizing by pixel
  /// counts alone squashes or stretches them.
  double? get displayAspect => _displayAspect;
  double? _displayAspect;

  /// Incremented on every open. An async callback from an older open is
  /// ignored rather than being allowed to overwrite newer state (spec §64).
  int _generation = 0;

  bool _disposed = false;

  /// Seek coalescing.
  Duration? _pendingSeekTarget;
  bool _seekInFlight = false;

  /// Position the picture last advanced at, for the live freeze watchdog.
  Duration _lastAdvance = Duration.zero;
  DateTime _lastAdvanceAt = DateTime.now();

  void _set(PlayerState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<void> _ensurePlayer() async {
    if (_player != null) return;
    final player = Player(
      configuration: const PlayerConfiguration(
        // Keep a modest demuxer cache: large buffers on a phone are the
        // fastest way to an OOM with a 4K stream (spec §46).
        bufferSize: 32 * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );
    _player = player;
    _videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        // Do NOT remove without confirming hardware decode actually renders
        // on real hardware first — see CLAUDE.md.
        hwdec: 'no',
        enableHardwareAcceleration: false,
      ),
    );
    _attachListeners(player);
  }

  void _attachListeners(Player player) {
    void sub<T>(Stream<T> stream, void Function(T) handler) {
      _subs.add(stream.listen(handler, onError: (Object e) {
        Log.w(_tag, 'stream error: $e');
      }));
    }

    sub(player.stream.playing, (playing) {
      if (_state.phase == PlaybackPhase.failed) return;
      _set(_state.copyWith(
        phase: playing ? PlaybackPhase.playing : PlaybackPhase.paused,
      ));
    });

    sub(player.stream.position, (position) {
      if (position != _lastAdvance) {
        _lastAdvance = position;
        _lastAdvanceAt = DateTime.now();
        _noteHealthy();
      }
      // While a seek is in flight the engine reports the old position; do not
      // fight the user's scrub with it.
      if (_seekInFlight) return;
      _set(_state.copyWith(position: position));
    });

    sub(player.stream.videoParams, (p) {
      final dw = p.dw, dh = p.dh;
      final a = p.aspect ??
          (dw != null && dh != null && dh > 0 ? dw / dh : null);
      if (a != null && a > 0 && a != _displayAspect) {
        _displayAspect = a;
        notifyListeners();
      }
    });

    sub(player.stream.duration, (duration) {
      _set(_state.copyWith(duration: duration));
    });

    sub(player.stream.buffer, (buffered) {
      _set(_state.copyWith(buffered: buffered));
    });

    sub(player.stream.buffering, (buffering) {
      if (_state.phase == PlaybackPhase.failed) return;
      if (buffering) {
        _set(_state.copyWith(phase: PlaybackPhase.buffering));
      } else if (_state.phase == PlaybackPhase.buffering) {
        // Leave "buffering" when the engine does. libmpv emits `playing`
        // once, usually *before* the first buffering stall, so waiting for
        // it to fire again left the UI on "Buffering..." (and a Play icon)
        // for the whole film while the video was actually running.
        _set(_state.copyWith(
          phase: player.state.playing
              ? PlaybackPhase.playing
              : PlaybackPhase.paused,
        ));
      }
    });

    sub(player.stream.completed, (completed) {
      if (completed && !_state.isLive) {
        _set(_state.copyWith(phase: PlaybackPhase.ended));
      }
    });

    sub(player.stream.error, (error) {
      Log.e(_tag, 'engine error: $error');
      _handleFailure(AppError(
        AppErrorKind.playback,
        'Unable to play this stream.',
        detail: error.toString(),
        retryable: true,
      ));
    });
  }

  /// Open [request]. Safe to call repeatedly (channel switching) — the same
  /// Player instance is reused, so the video surface never tears down.
  Future<void> open(PlaybackRequest request) async {
    if (_disposed) return;
    final generation = ++_generation;

    _cancelTimers();
    _set(PlayerState(
      phase: PlaybackPhase.opening,
      request: request,
      retryAttempt: 0,
    ));

    await _ensurePlayer();
    if (generation != _generation || _disposed) return;

    final previous = _active;
    if (previous != null && !identical(previous, this)) {
      Log.i(_tag, 'stopping the previous player before a new playback');
      await previous.stop();
      if (generation != _generation || _disposed) return;
    }
    _active = this;

    // A local file needs no provider connection at all (spec §29).
    if (request.isLocal) {
      await _openMedia(request, generation);
      return;
    }

    // Take the single provider connection. Playback pre-empts downloads.
    _lease?.release();
    try {
      _lease = await _guard.acquire(
        ProviderUse.playback,
        label: request.historyKey,
      );
    } on TimeoutException {
      _handleFailure(const AppError(
        AppErrorKind.playback,
        'Another stream is still closing. Try again in a moment.',
        retryable: true,
      ));
      return;
    }
    if (generation != _generation || _disposed) {
      _lease?.release();
      _lease = null;
      return;
    }

    // No HEAD "probe" before opening — AUDIT.md §3 forbids "probe the
    // stream then play it" on a one-connection account, and on a real panel
    // it was actively harmful: otv.to answers HEAD with 520 text/plain (or
    // nothing at all) for episodes that play fine over GET, so every such
    // episode failed with "Unable to play this stream" before libmpv was
    // ever asked, and the probe's keep-alive socket could itself be counted
    // against max_connections=1. libmpv opens the URL directly, exactly as
    // the PC app does; a genuinely bad URL (HTML error page, 404) fails in
    // the player and is reported through the normal error path.
    await _openMedia(request, generation);
  }

  Future<void> _openMedia(PlaybackRequest request, int generation) async {
    final player = _player;
    if (player == null) return;
    try {
      await player.open(
        Media(
          request.resolvedSource,
          // Resume by starting the stream at the saved position rather than
          // seeking after playback begins — AUDIT.md §3.
          start: request.startAt > Duration.zero ? request.startAt : null,
          httpHeaders: request.isLocal
              ? null
              : const {'User-Agent': Api.downloadUserAgent},
        ),
        play: true,
      );
      if (generation != _generation || _disposed) return;
      _set(_state.copyWith(
        phase: PlaybackPhase.buffering,
        position: request.startAt,
        clearError: true,
      ));
      if (request.isLive) _armLiveWatchdog(generation);
    } catch (e, st) {
      if (generation != _generation || _disposed) return;
      Log.e(_tag, 'open failed', e, st);
      _handleFailure(AppError(
        AppErrorKind.playback,
        'Unable to play this stream.',
        detail: e.toString(),
        retryable: true,
      ));
    }
  }

  /// Live-only freeze/stall watchdog, matching the PC app's
  /// `_armFreezeWatchdog` and its ~12s stall timeout with 3 retries.
  void _armLiveWatchdog(int generation) {
    _stallWatchdog?.cancel();
    _lastAdvance = Duration.zero;
    _lastAdvanceAt = DateTime.now();
    _stallWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed || generation != _generation) return;
      if (_state.phase == PlaybackPhase.failed) return;
      final stalledFor = DateTime.now().difference(_lastAdvanceAt);
      if (stalledFor < Playback.liveStallTimeout) return;
      Log.w(_tag, 'live stream stalled for ${stalledFor.inSeconds}s — reloading');
      _retryCurrent(generation);
    });
  }

  /// When the stream last started advancing without interruption.
  DateTime? _healthySince;

  /// The live retry budget (Playback.liveMaxRetries) is for a channel that
  /// will not come up, and CLAUDE.md keeps it at 3 so dead channels fail
  /// fast. It is not a lifetime allowance: once a recovered stream has
  /// played cleanly for a while the budget is restored. Before this, three
  /// brief network blips spread over an hour of viewing used it up and the
  /// fourth showed "Unable to play this stream" on a channel that was fine.
  void _noteHealthy() {
    if (_state.retryAttempt == 0) {
      _healthySince = null;
      return;
    }
    final now = DateTime.now();
    _healthySince ??= now;
    if (now.difference(_healthySince!) >= const Duration(seconds: 15)) {
      Log.i(_tag, 'stream healthy again — retry budget restored');
      _healthySince = null;
      _set(_state.copyWith(retryAttempt: 0));
    }
  }

  void _handleFailure(AppError error) {
    if (_disposed) return;
    _healthySince = null;
    _cancelTimers();
    final request = _state.request;
    final attempt = _state.retryAttempt;

    // Live channels get the PC app's 3 retries with backoff before the user
    // sees anything; VOD failures surface immediately.
    if (request != null &&
        request.isLive &&
        error.retryable &&
        attempt < Playback.liveMaxRetries) {
      final delay = Duration(milliseconds: 800 * (1 << attempt));
      Log.i(_tag, 'live retry ${attempt + 1}/${Playback.liveMaxRetries} in ${delay.inMilliseconds}ms');
      _set(_state.copyWith(
        phase: PlaybackPhase.buffering,
        retryAttempt: attempt + 1,
      ));
      final generation = _generation;
      _retryTimer = Timer(delay, () => _retryCurrent(generation));
      return;
    }

    _lease?.release();
    _lease = null;
    _set(_state.copyWith(phase: PlaybackPhase.failed, error: error));
  }

  void _retryCurrent(int generation) {
    if (_disposed || generation != _generation) return;
    _healthySince = null;
    final request = _state.request;
    if (request == null) return;
    final attempt = _state.retryAttempt;
    // Resume where it stopped rather than restarting the item.
    final resumeFrom = request.isLive ? Duration.zero : _state.position;
    _stallWatchdog?.cancel();
    unawaited(() async {
      final keepAttempt = attempt;
      await open(request.copyWith(startAt: resumeFrom));
      if (!_disposed) {
        _set(_state.copyWith(retryAttempt: keepAttempt));
      }
    }());
  }

  /// Manual retry from the error overlay.
  Future<void> retry() async {
    final request = _state.request;
    if (request == null) return;
    _set(_state.copyWith(retryAttempt: 0, clearError: true));
    await open(request);
  }

  Future<void> playPause() async {
    final player = _player;
    if (player == null) return;
    await player.playOrPause();
  }

  Future<void> play() async => _player?.play();

  Future<void> pause() async => _player?.pause();

  /// Relative seek used by the ±10 controls and the D-pad.
  ///
  /// Spec §21: pressing +10 four times fast must move 40s with ONE seek in
  /// flight, not four racing ones. The target accumulates against the last
  /// requested position, so the overlay and the engine agree.
  Future<void> seekBy(Duration delta) async {
    if (_state.isLive) return;
    final base = _pendingSeekTarget ?? _state.position;
    var target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    final duration = _state.duration;
    if (duration > Duration.zero && target > duration) target = duration;

    _pendingSeekTarget = target;
    // Show the user the destination immediately; the engine catches up.
    _set(_state.copyWith(position: target));
    await _drainSeeks();
  }

  Future<void> seekTo(Duration target) async {
    if (_state.isLive) return;
    _pendingSeekTarget = target;
    _set(_state.copyWith(position: target));
    await _drainSeeks();
  }

  Future<void> _drainSeeks() async {
    if (_seekInFlight) return;
    final player = _player;
    if (player == null) return;

    _seekInFlight = true;
    try {
      while (_pendingSeekTarget != null && !_disposed) {
        final target = _pendingSeekTarget!;
        _pendingSeekTarget = null;
        try {
          await player.seek(target);
        } catch (e) {
          Log.w(_tag, 'seek failed: $e');
          break;
        }
      }
    } finally {
      _seekInFlight = false;
    }
  }

  Future<void> setSpeed(double speed) async => _player?.setRate(speed);

  Future<void> setVolume(double volume) async =>
      _player?.setVolume(volume.clamp(0, 100));

  /// Real tracks only. libmpv also lists the pseudo-tracks "auto" and "no";
  /// the tracks dialog offers "no" as its own Disable row.
  static bool _real(String id) => id != 'auto' && id != 'no';

  List<VideoTrack> get videoTracks =>
      (_player?.state.tracks.video ?? const <VideoTrack>[])
          .where((t) => _real(t.id))
          .toList();

  /// The currently selected tracks (ids "no" when disabled).
  VideoTrack? get currentVideoTrack => _player?.state.track.video;
  AudioTrack? get currentAudioTrack => _player?.state.track.audio;
  SubtitleTrack? get currentSubtitleTrack => _player?.state.track.subtitle;

  Future<void> setVideoTrack(VideoTrack track) async =>
      _player?.setVideoTrack(track);

  List<AudioTrack> get audioTracks =>
      (_player?.state.tracks.audio ?? const <AudioTrack>[])
          .where((t) => _real(t.id))
          .toList();
  List<SubtitleTrack> get subtitleTracks =>
      (_player?.state.tracks.subtitle ?? const <SubtitleTrack>[])
          .where((t) => _real(t.id))
          .toList();

  Future<void> setAudioTrack(AudioTrack track) async =>
      _player?.setAudioTrack(track);

  Future<void> setSubtitleTrack(SubtitleTrack track) async =>
      _player?.setSubtitleTrack(track);

  /// Stop playback and hand the provider connection back, without tearing
  /// down the Player — used when the inline Live TV screen goes idle.
  Future<void> stop() async {
    if (identical(_active, this)) _active = null;
    _cancelTimers();
    _generation++;
    try {
      await _player?.stop();
    } catch (e) {
      Log.w(_tag, 'stop failed: $e');
    }
    _lease?.release();
    _lease = null;
    _set(const PlayerState());
  }

  void _cancelTimers() {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// Spec §25: everything goes. No leaked timers, subscriptions or engine
  /// resources.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_active, this)) _active = null;
    _generation++;
    _cancelTimers();

    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();

    _lease?.release();
    _lease = null;

    final player = _player;
    _player = null;
    _videoController = null;
    try {
      await player?.dispose();
    } catch (e) {
      Log.w(_tag, 'player dispose failed: $e');
    }

    super.dispose();
  }
}
