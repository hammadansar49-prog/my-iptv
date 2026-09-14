// Player module: wraps <video>, hls.js and mpegts.js, drives the custom control bar.
class PlayerController {
  constructor(videoEl) {
    this.video = videoEl;
    this.hls = null;
    this.mpegts = null;
    this.isLive = false;
    this.onStateChange = null;
    this.quality = 'auto';
    this.proxyBase = null;

    this._playToken = 0;
    this._originalUrl = null;
    this._stage = 'idle';
    this._stallTimer = null;
    this.onFps = null;
    this._fpsTimer = null;
    this._lastFrames = 0;
    this._fixedDuration = null;
    this._maxDuration = 0;
    this._seekOffset = 0;
    this._lastMode = 'copy';
    this._seekRecoverTimer = null;
    this._seeking = false;
    this._dataReceived = false;
    this._seekGeneration = 0;

    this.video.addEventListener('error', () => this._onVideoError());
    this.video.addEventListener('loadeddata', () => this._onReady());
    this.video.addEventListener('playing', () => this._onReady());
  }

  setProxyBase(base) { this.proxyBase = base; }
  setQuality(q) { this.quality = q; }

  destroy() {
    this._playToken++;
    this._clearStallTimer();
    this._seeking = false;
    this._dataReceived = false;
    this._seekGeneration++;
    if (this._seekRecoverTimer) { clearTimeout(this._seekRecoverTimer); this._seekRecoverTimer = null; }
    this._stopFpsLoop();
    try { if (this.hls) { this.hls.destroy(); this.hls = null; } } catch {}
    try { if (this.mpegts) { this.mpegts.destroy(); this.mpegts = null; } } catch {}
    this.video.removeAttribute('src');
    this.video.load();
  }

  _onReady() {
    this._dataReceived = true;
    this._clearStallTimer();
    this._startFpsLoop();
    this._notify('playing');
  }

  _armStallTimer(token, ms) {
    this._clearStallTimer();
    this._stallTimer = setTimeout(() => {
      if (token !== this._playToken) return;
      if (this._dataReceived) return;
      this._onVideoError();
    }, ms);
  }
  _clearStallTimer() {
    if (this._stallTimer) { clearTimeout(this._stallTimer); this._stallTimer = null; }
  }

  _startFpsLoop() {
    this._stopFpsLoop();
    if (!this.video.getVideoPlaybackQuality) return;
    let lastFrames = this.video.getVideoPlaybackQuality().totalVideoFrames;
    this._fpsTimer = setInterval(() => {
      const q = this.video.getVideoPlaybackQuality();
      const fps = Math.max(0, q.totalVideoFrames - lastFrames);
      lastFrames = q.totalVideoFrames;
      if (this.onFps) this.onFps(fps);
    }, 1000);
  }
  _stopFpsLoop() {
    if (this._fpsTimer) { clearInterval(this._fpsTimer); this._fpsTimer = null; }
    if (this.onFps) this.onFps(null);
  }

  _notify(status, extra) { if (this.onStateChange) this.onStateChange(status, extra); }

  play(url, { isLive = false } = {}) {
    this.destroy();
    this.isLive = isLive;
    this._originalUrl = url;
    this._fixedDuration = null;
    this._maxDuration = 0;
    this._seekOffset = 0;
    this._lastMode = 'copy';
    this._probeResult = null;
    const token = this._playToken;
    console.log(`[player] play() url=${url} isLive=${isLive}`);
    this._notify('loading');
    this._playDirect(url, token);
  }

  getDisplayDuration() {
    if (this._fixedDuration) return this._fixedDuration;
    const raw = this.video.duration;
    if (isFinite(raw) && raw > this._maxDuration) this._maxDuration = raw;
    return this._maxDuration || raw;
  }

  getDisplayCurrentTime() {
    return this._seekOffset + (this.video.currentTime || 0);
  }

  _playDirect(url, token) {
    this._stage = 'direct';
    const lower = url.split('?')[0].toLowerCase();

    if (lower.endsWith('.m3u8')) {
      this._playHls(url, token);
      return;
    }

    if (lower.endsWith('.ts') || (this.isLive && !lower.endsWith('.m3u8'))) {
      this._playMpegts(url, token);
      return;
    }

    const knownIncompatible = ['.mkv', '.avi', '.flv', '.wmv', '.rmvb', '.vob'];
    if (knownIncompatible.some((ext) => lower.endsWith(ext))) {
      if (this.isLive) {
        this._playProxy(url, token, 'copy');
        return;
      }
      if (!this.proxyBase) {
        setTimeout(() => { if (token === this._playToken) this._playDirect(url, token); }, 150);
        return;
      }
      // Start copy immediately (fast for AAC/MP3). Probe in _playProxy for audio codec.
      this._playProxy(url, token, 'copy');
      return;
    }

    console.log('[player] trying native <video> playback');
    this.video.src = url;
    this.video.play().catch(() => {});
    this._armStallTimer(token, 3000);
  }

  _playHls(url, token) {
    if (window.Hls && window.Hls.isSupported()) {
      this.hls = new window.Hls({
        maxBufferLength: 30,
        maxMaxBufferLength: 60,
        liveSyncDuration: 3,
        liveMaxLatencyDuration: 10,
        enableWorker: true,
        lowLatencyMode: false,
        manifestLoadingTimeOut: 8000,
        manifestLoadingMaxRetry: 2,
        levelLoadingTimeOut: 8000,
        fragLoadingTimeOut: 12000
      });
      this.hls.loadSource(url);
      this.hls.attachMedia(this.video);
      this.hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
        if (token !== this._playToken) return;
        this._applyHlsQuality();
        this.video.play().catch(() => {});
        this._notify('playing');
      });
      this._armStallTimer(token, 6000);
      this.hls.on(window.Hls.Events.ERROR, (_e, data) => {
        if (token !== this._playToken) return;
        if (data.fatal) {
          switch (data.type) {
            case window.Hls.ErrorTypes.NETWORK_ERROR:
              this._notify('buffering');
              this.hls.startLoad();
              break;
            case window.Hls.ErrorTypes.MEDIA_ERROR:
              this._notify('buffering');
              this.hls.recoverMediaError();
              break;
            default:
              this._fallback(token, 'This stream is unavailable.');
              break;
          }
        }
      });
    } else if (this.video.canPlayType('application/vnd.apple.mpegurl')) {
      this.video.src = url;
      this.video.play().catch(() => {});
      this._notify('playing');
    } else {
      this._fallback(token, 'HLS playback is not supported.');
    }
  }

  _applyHlsQuality() {
    if (!this.hls || this.quality === 'auto') {
      if (this.hls) this.hls.currentLevel = -1;
      return;
    }
    const targetH = { '480': 480, '720': 720, '1080': 1080, '2160': 2160 }[this.quality];
    if (!targetH || !this.hls.levels || !this.hls.levels.length) return;
    let bestIdx = -1, bestDiff = Infinity;
    this.hls.levels.forEach((lvl, idx) => {
      const diff = Math.abs((lvl.height || 0) - targetH);
      if (diff < bestDiff) { bestDiff = diff; bestIdx = idx; }
    });
    if (bestIdx >= 0) this.hls.currentLevel = bestIdx;
  }

  _playMpegts(url, token) {
    if (window.mpegts && window.mpegts.isSupported()) {
      this.mpegts = window.mpegts.createPlayer({ type: 'mpegts', isLive: true, url }, {
        enableWorker: true,
        liveBufferLatencyChasing: true,
        liveBufferLatencyMaxLatency: 6,
        liveBufferLatencyMinRemain: 2
      });
      this.mpegts.attachMediaElement(this.video);
      this.mpegts.load();
      this.mpegts.play().catch(() => {});
      this.mpegts.on(window.mpegts.Events.ERROR, () => {
        if (token !== this._playToken) return;
        this._fallback(token, 'This channel format is unsupported.');
      });
      this._notify('playing');
      this._armStallTimer(token, 6000);
      return;
    }
    this._fallback(token, null);
  }

  _onVideoError() {
    if (this._seeking) return;
    if (this._dataReceived) return;
    const token = this._playToken;
    console.log(`[player] _onVideoError stage=${this._stage} err=${this.video.error ? this.video.error.code : 'none'}`);
    // During a seek that's waiting for cache to grow, the server is
    // legitimately not sending data yet — don't cascade through fallback
    // modes which would waste time re-downloading from scratch.
    if (this._stage.startsWith('proxy') && this._seekOffset > 0) {
      console.log('[player] seek stall — re-arming long timer');
      this._dataReceived = false;
      this._armStallTimer(token, 120000);
      return;
    }
    const resumeAt = this._stage.startsWith('proxy') ? this.getDisplayCurrentTime() : 0;
    if (this._stage === 'direct') {
      this._fallback(token, 'Trying a compatible format...');
    } else if (this._stage === 'proxy-copy') {
      this._dataReceived = false;
      this._playProxy(this._originalUrl, token, 'audiofix', resumeAt);
    } else if (this._stage === 'proxy-audiofix') {
      this._dataReceived = false;
      this._playProxy(this._originalUrl, token, 'transcode', resumeAt);
    } else if (this._stage === 'proxy-transcode') {
      this._notify('error:final', 'Stream could not be played. The server may be down or blocking connections.');
    }
  }

  _fallback(token, message, skipCopy = false) {
    if (token !== this._playToken) return;
    if (this._stage === 'direct' && !skipCopy) {
      if (message) this._notify('buffering', message);
      this._playProxy(this._originalUrl, token, 'copy', 0);
    } else if (this._stage === 'proxy-copy' || skipCopy) {
      this._playProxy(this._originalUrl, token, 'audiofix', 0);
    } else if (this._stage === 'proxy-audiofix') {
      this._playProxy(this._originalUrl, token, 'transcode', 0);
    } else {
      this._notify('error:final', message || 'This stream could not be played.');
    }
  }

  _playProxy(originalUrl, token, mode, seekSec = 0, waitedMs = 0) {
    if (!this.proxyBase) {
      if (waitedMs >= 5000) {
        this._notify('error:final', 'Playback helper is not ready yet — please retry.');
        return;
      }
      setTimeout(() => {
        if (token === this._playToken) this._playProxy(originalUrl, token, mode, seekSec, waitedMs + 150);
      }, 150);
      return;
    }
    this._stage = mode === 'copy' ? 'proxy-copy' : mode === 'audiofix' ? 'proxy-audiofix' : 'proxy-transcode';
    this._lastMode = mode;
    this._seekOffset = seekSec || 0;
    this._dataReceived = false;
    this._notify('buffering', 'Preparing stream...');

    const startStream = (finalMode) => {
      if (token !== this._playToken) return;
      this._stage = finalMode === 'copy' ? 'proxy-copy' : finalMode === 'audiofix' ? 'proxy-audiofix' : 'proxy-transcode';
      this._lastMode = finalMode;
      if (!this.isLive && !this._fixedDuration) {
        fetch(`${this.proxyBase}/probe?url=${encodeURIComponent(originalUrl)}`)
          .then((r) => r.json())
          .then((d) => {
            if (token === this._playToken && d && d.duration) this._fixedDuration = d.duration;
          })
          .catch(() => {});
      }
      const proxied = `${this.proxyBase}/stream?url=${encodeURIComponent(originalUrl)}&mode=${finalMode}&live=${this.isLive ? '1' : '0'}&seek=${this._seekOffset}&t=${Date.now()}`;
      console.log(`[player] _playProxy mode=${finalMode} seek=${this._seekOffset}`);
      this.video.src = proxied;
      this.video.play().then(() => {
        if (token === this._playToken) this._notify('playing');
      }).catch(() => {});
      this._armStallTimer(token, this._seekOffset > 0 ? 120000 : 40000);
    };

    // On seeks (seekSec > 0), skip probe — use cached result from initial play.
    // This saves 4+ seconds on every seek.
    if (mode === 'copy' && !this.isLive && !seekSec) {
      fetch(`${this.proxyBase}/probe?url=${encodeURIComponent(originalUrl)}`)
        .then((r) => r.json())
        .then((d) => {
          if (token !== this._playToken) return;
          if (d && d.duration) this._fixedDuration = d.duration;
          this._probeResult = d;
          const audio = d && d.audioCodec;
          if (audio && ['ac3', 'eac3', 'dts', 'truehd'].includes(audio.toLowerCase())) {
            console.log(`[player] probe: audio=${audio} -> audiofix`);
            startStream('audiofix');
          } else {
            console.log(`[player] probe: audio=${audio || 'unknown'} -> copy`);
            startStream('copy');
          }
        })
        .catch(() => {
          startStream(mode);
        });
      return;
    }

    // On seeks with copy mode, use cached probe result to pick the right mode
    if (mode === 'copy' && this._probeResult) {
      const audio = this._probeResult && this._probeResult.audioCodec;
      if (audio && ['ac3', 'eac3', 'dts', 'truehd'].includes(audio.toLowerCase())) {
        console.log(`[player] seek: cached probe audio=${audio} -> audiofix`);
        startStream('audiofix');
      } else {
        console.log(`[player] seek: cached probe audio=${audio || 'unknown'} -> copy`);
        startStream('copy');
      }
      return;
    }

    startStream(mode);
  }

  togglePlayPause() {
    if (this.video.paused) this.video.play().catch(() => {});
    else this.video.pause();
  }

  seekTo(targetSeconds) {
    const dur = this.getDisplayDuration();
    let seconds = Math.max(0, targetSeconds);
    if (isFinite(dur) && dur > 0) seconds = Math.min(seconds, Math.max(0, dur - 0.5));

    if (this._stage === 'direct') {
      if (isFinite(this.video.duration)) this.video.currentTime = seconds;
      return;
    }

    if (this._stage.startsWith('proxy')) {
      const relativeTarget = seconds - this._seekOffset;

      // Check if the target is within the already-buffered range.
      // VOD cache serves a growing fragmented MP4 — Chromium parses moof
      // boxes as they arrive, so video.buffered IS accurate here.
      let inBuffer = false;
      for (let i = 0; i < this.video.buffered.length; i++) {
        if (relativeTarget >= this.video.buffered.start(i) - 1 && relativeTarget <= this.video.buffered.end(i) + 1) {
          inBuffer = true;
          break;
        }
      }

      if (inBuffer) {
        // Data already downloaded — seek instantly, no loading.
        // Suppress errors during direct seek — Chromium may fire a
        // transient decode error when jumping within fragmented MP4.
        this._seeking = true;
        this.video.currentTime = relativeTarget;
        const clearSeeking = () => {
          this._seeking = false;
          this.video.removeEventListener('playing', clearSeeking);
          this.video.removeEventListener('pause', clearSeeking);
        };
        this.video.addEventListener('playing', clearSeeking);
        this.video.addEventListener('pause', clearSeeking);
        setTimeout(clearSeeking, 1000);
        return;
      }

      // Beyond buffer — restart ffmpeg at the target.
      console.log(`[player] seekTo: NOT buffered, restarting ffmpeg at ${seconds.toFixed(1)}s`);
      if (this._seekRecoverTimer) { clearTimeout(this._seekRecoverTimer); this._seekRecoverTimer = null; }
      this._clearStallTimer();
      this._dataReceived = false;
      this._notify('buffering', 'Seeking...');
      this._playProxy(this._originalUrl, this._playToken, this._lastMode || 'copy', seconds);
    }
  }

  seekRelative(seconds) {
    const dur = this.getDisplayDuration();
    if (!isFinite(dur)) return;
    this.seekTo(this.getDisplayCurrentTime() + seconds);
  }

  setSpeed(rate) { this.video.playbackRate = rate; }
  setVolume(v) { this.video.volume = v; this.video.muted = v === 0; }
  toggleMute() { this.video.muted = !this.video.muted; }
}

window.PlayerController = PlayerController;
