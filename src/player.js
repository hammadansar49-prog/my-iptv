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
    this._pendingSeek = 0;
    this._lastMode = 'copy';
    this._seekRecoverTimer = null;
    this._seeking = false;
    this._dataReceived = false;
    this._seekGeneration = 0;
    this._startAt = 0;
    this._mseStalls = 0;
    // Tags every request to the local proxy with the playback it belongs to
    // (see admitSession in main.js). Starts from the clock so ids keep
    // growing across a page reload.
    this._sidBase = Date.now() * 1000;

    this.video.addEventListener('error', () => this._onVideoError());
    this.video.addEventListener('loadeddata', () => this._onReady());
    this.video.addEventListener('playing', () => this._onReady());
  }

  setProxyBase(base) { this.proxyBase = base; }
  setQuality(q) { this.quality = q; }

  // Only qualities this particular stream can really deliver. A source's
  // own resolution is the ceiling — a 720p file never offers 1080p or 4K,
  // because that would just be the same picture blown up. Lower steps are
  // genuine re-encodes. HLS streams list whatever variants the provider
  // actually publishes.
  getQualityOptions() {
    if (this.hls && this.hls.levels && this.hls.levels.length > 1) {
      const current = this.hls.autoLevelEnabled ? -1 : this.hls.currentLevel;
      const seen = new Set();
      const levels = this.hls.levels
        .map((l, i) => ({ height: l.height, index: i }))
        .filter((l) => l.height && !seen.has(l.height) && seen.add(l.height))
        .sort((a, b) => b.height - a.height)
        .map((l) => ({ id: `hls:${l.index}`, label: qualityLabel(l.height), active: current === l.index }));
      return [{ id: 'hls:-1', label: 'Auto', active: current === -1 }, ...levels];
    }

    const nativeHeight = this.video.videoHeight || 0;
    if (!this._stage || !this._stage.startsWith('proxy') || this.isLive || !this._sourceHeight) {
      return nativeHeight ? [{ id: 'native', label: `${qualityLabel(nativeHeight)} (source)`, active: true }] : [];
    }

    const scaled = /^scale(\d+)$/.exec(this._lastMode || '');
    const currentHeight = scaled ? parseInt(scaled[1], 10) : 0;
    const steps = [1440, 1080, 720, 480, 360].filter((h) => h < this._sourceHeight - 20);
    return [
      { id: 'vod:0', label: `${qualityLabel(this._sourceHeight)} (original)`, active: currentHeight === 0 },
      ...steps.map((h) => ({ id: `vod:${h}`, label: qualityLabel(h), active: currentHeight === h }))
    ];
  }

  selectQuality(id) {
    const [kind, raw] = String(id).split(':');
    const value = parseInt(raw, 10);

    if (kind === 'hls' && this.hls) {
      this.hls.currentLevel = value; // -1 hands control back to hls.js
      return;
    }
    if (kind !== 'vod' || !this._originalUrl) return;

    const target = value > 0 ? `scale${value}` : (this._baseMode || 'copy');
    if (target === this._lastMode) return;

    // Carry on from the same moment in the new quality.
    const resumeAt = this.getDisplayCurrentTime();
    console.log(`[player] quality -> ${target} at ${resumeAt.toFixed(1)}s`);
    this._clearStallTimer();
    this._dataReceived = false;
    this._notify('buffering', 'Switching quality...');
    this._playProxy(this._originalUrl, this._playToken, target, resumeAt);
  }

  _sid(token) { return this._sidBase + token; }

  // Stops hls.js / mpegts.js if either is attached. Both keep fetching from
  // the provider on their own until destroyed, even after the element has
  // moved on to another source — which on a one-connection account starves
  // whatever was started instead.
  _teardownEngines() {
    try { if (this.hls) { this.hls.destroy(); } } catch {}
    this.hls = null;
    try { if (this.mpegts) { this.mpegts.destroy(); } } catch {}
    this.mpegts = null;
  }

  destroy() {
    this._playToken++;
    this._clearStallTimer();
    this._seeking = false;
    this._dataReceived = false;
    this._seekGeneration++;
    if (this._seekRecoverTimer) { clearTimeout(this._seekRecoverTimer); this._seekRecoverTimer = null; }
    if (this._cachePollTimer) { clearInterval(this._cachePollTimer); this._cachePollTimer = null; }
    if (this._hlsRetryTimer) { clearTimeout(this._hlsRetryTimer); this._hlsRetryTimer = null; }
    if (this._subTimer) { clearInterval(this._subTimer); this._subTimer = null; }
    if (this._mse) { try { this._mse.destroy(); } catch {} this._mse = null; }
    this._clearFreezeWatchdog();
    this._clearAudioWatchdog();
    this._stopFpsLoop();
    this._teardownEngines();
    this.video.removeAttribute('src');
    this.video.load();
    // Tell the proxy this playback is over, so its download and any seek
    // stop holding the provider connection right now rather than after an
    // idle timeout — the next film or channel needs it.
    if (this.proxyBase) {
      fetch(`${this.proxyBase}/release?sid=${this._sid(this._playToken)}`, { cache: 'no-store' }).catch(() => {});
    }
  }

  _onReady() {
    this._dataReceived = true;
    this._liveReloadAttempts = 0;
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

  // hls.js/mpegts.js only raise an error when the *network* fails — a live
  // channel that goes silently frozen (decoder wedged on a corrupt frame,
  // or stuck waiting on a buffer that never fills) never fires one, so it
  // just sits there with no message at all. This watches actual playback
  // progress directly: if currentTime stops moving for a few seconds while
  // the video isn't paused and isn't merely waiting on empty buffer, first
  // try a tiny nudge (unwedges a lot of decoder stalls on its own); if that
  // doesn't help, rebuild the whole engine at the same live edge.
  _armFreezeWatchdog(token) {
    this._clearFreezeWatchdog();
    if (!this.isLive) return;
    let lastTime = -1;
    let stuckTicks = 0;
    let starvedTicks = 0;
    const reload = (why) => {
      // A one-connection provider needs a moment to actually let go of the
      // connection this reconnect attempt just tore down — reconnecting
      // instantly (as this used to) can ask for a new one before the old
      // slot is released server-side, so the new attempt gets refused too,
      // which looked identical to the original stall ("still loading")
      // except now it repeated forever every ~10s instead of just once.
      // Backing off a little more on each consecutive failed reconnect (reset
      // the moment a reconnect actually gets data again, in _onReady) gives
      // the provider time to catch up instead of racing it.
      this._liveReloadAttempts = (this._liveReloadAttempts || 0) + 1;
      const delay = Math.min(6000, 1200 * this._liveReloadAttempts);
      console.log(`[player] ${why} — reloading channel in ${delay}ms (attempt ${this._liveReloadAttempts})`);
      this._clearFreezeWatchdog();
      this._notify('buffering', 'Reconnecting...');
      const url = this._originalUrl;
      this._teardownEngines();
      setTimeout(() => {
        if (token !== this._playToken) return;
        this._playDirect(url, token);
      }, delay);
    };
    this._freezeWatchdog = setInterval(() => {
      if (token !== this._playToken || this.video.paused || this.video.seeking) {
        stuckTicks = 0; starvedTicks = 0; lastTime = this.video.currentTime;
        return;
      }
      const hasBufferAhead = Array.from({ length: this.video.buffered.length }, (_, i) => i)
        .some((i) => this.video.buffered.end(i) - this.video.currentTime > 0.5);
      const t = this.video.currentTime;
      if (t > lastTime + 0.05) {
        stuckTicks = 0; starvedTicks = 0; lastTime = t;
        return;
      }
      lastTime = t;
      if (!hasBufferAhead) {
        // Not the same thing as a decoder stuck on a full buffer (below) —
        // here nothing is arriving at all, so nudging currentTime has
        // nothing to nudge into and never helped. That used to reset the
        // stuck-tick counter to 0 every single tick (treated as "just
        // buffering, leave it alone"), so a connection that truly stopped
        // delivering data was left spinning on "Loading..." forever with no
        // way back except the user manually pausing and pressing play again.
        // Its own longer counter now forces the same reconnect once it's
        // clearly not a brief, normal buffering pause.
        stuckTicks = 0;
        starvedTicks++;
        if (starvedTicks >= 10) { starvedTicks = 0; reload('live playback starved (no incoming data)'); }
        return;
      }
      starvedTicks = 0;
      stuckTicks++;
      if (stuckTicks === 3) {
        console.log('[player] live playback frozen — nudging');
        try { this.video.currentTime = t + 0.2; } catch {}
      } else if (stuckTicks >= 6) {
        reload('live playback still frozen after nudge');
      }
    }, 1000);
  }
  _clearFreezeWatchdog() {
    if (this._freezeWatchdog) { clearInterval(this._freezeWatchdog); this._freezeWatchdog = null; }
  }

  // ---- Silent audio on channels Chromium claims it can decode ----
  //
  // The BUFFER_CODECS check in _playHls catches audio codecs MediaSource
  // openly refuses. Some (notably AC-3/E-AC-3 on this Chromium/Windows
  // build) pass isTypeSupported() and hls.js appends them without any
  // error, yet no PCM ever comes out — the picture plays perfectly and the
  // channel is just silent forever. That can only be told apart from "no
  // audio track at all" by watching whether Chromium is actually decoding
  // any audio bytes once real playback is underway.
  _armAudioWatchdog(token) {
    this._clearAudioWatchdog();
    if (typeof this.video.webkitAudioDecodedByteCount !== 'number') return; // not this Chromium build
    let goodTicks = 0;
    this._audioWatchdog = setInterval(() => {
      if (token !== this._playToken) { this._clearAudioWatchdog(); return; }
      // Only counts once picture is genuinely flowing — otherwise a slow
      // start looks identical to a silent channel for the first second.
      if (this.video.paused || this.video.videoWidth === 0) return;
      if (this.video.webkitAudioDecodedByteCount > 0) { this._clearAudioWatchdog(); return; }
      goodTicks++;
      if (goodTicks >= 4) {
        this._clearAudioWatchdog();
        if (this._lastMode === 'audiofix' || this._lastMode === 'transcode') {
          // Already tried re-encoding the audio and it's still silent — at
          // this point the provider's own feed for this channel almost
          // certainly has no audio track at all, not a codec problem we can
          // fix. Say so plainly instead of leaving the picture up with no
          // sound and no explanation.
          console.log('[player] still no audio after re-encoding — this channel likely has none in the source');
          this._notify('no-audio', 'This channel appears to have no audio in the broadcast.');
          return;
        }
        console.log(`[player] no audio decoded after ${goodTicks}s of picture — switching to audio-fix mode`);
        const at = this._stage.startsWith('proxy') ? this.getDisplayCurrentTime() : this._startAt;
        this._teardownEngines();
        this._notify('buffering', 'Fixing audio...');
        // A one-connection provider account can take a moment to let go of
        // the connection hls.js/mpegts.js was just using — asking for a new
        // one immediately sometimes gets refused or left hanging. A short
        // pause here comfortably covers that hand-off.
        setTimeout(() => {
          if (token !== this._playToken) return;
          this._playProxy(this._originalUrl, token, 'audiofix', at);
          this._armAudioWatchdog(token);
        }, 700);
      }
    }, 1000);
  }
  _clearAudioWatchdog() {
    if (this._audioWatchdog) { clearInterval(this._audioWatchdog); this._audioWatchdog = null; }
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

  // startAt: where to begin (a saved resume position). Opening the stream
  // right there is what makes resuming quick — starting at 0 and seeking
  // once the first frames arrive meant two stream setups back to back.
  play(url, { isLive = false, startAt = 0 } = {}) {
    this.destroy();
    this.isLive = isLive;
    this._originalUrl = url;
    this._fixedDuration = null;
    this._maxDuration = 0;
    this._seekOffset = 0;
    this._pendingSeek = 0;
    this._startAt = !isLive && startAt > 0 ? startAt : 0;
    this._lastMode = 'copy';
    this._baseMode = 'copy';
    this._liveReloadAttempts = 0;
    this._sourceHeight = 0;
    this._probeResult = null;
    this._audioIndex = 0;
    this._mseStarting = false;
    if (this._subTimer) { clearInterval(this._subTimer); this._subTimer = null; }
    this._subIndex = -1;
    this._subCues = [];
    this._subAfter = 0;
    this._clearSubtitleTrack();
    if (this._textTrack) this._textTrack.mode = 'disabled';
    this._mseDisabled = false;
    this._mseStalls = 0;
    this._hlsNetworkErrors = 0;
    this._hlsMediaErrors = 0;
    const token = this._playToken;
    console.log(`[player] play() url=${url} isLive=${isLive}${this._startAt ? ` startAt=${this._startAt.toFixed(1)}` : ''}`);
    // Watching from the provider takes its one connection: a download that is
    // running pauses until playback ends. A downloaded file needs nothing.
    if (this.proxyBase && !/^file:/i.test(url)) {
      fetch(`${this.proxyBase}/claim?sid=${this._sid(token)}`, { cache: 'no-store' }).catch(() => {});
    }
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
    // While a new MediaSource is being set up (quality or audio switch, a
    // resume) the element briefly reports 0:00; the position being opened is
    // the honest answer, so the seek bar doesn't jump back to the start.
    if (this._mse && this._mseStarting) return this._pendingSeek || 0;
    return this._seekOffset + (this.video.currentTime || 0);
  }

  // ---- Audio tracks ----

  getAudioOptions() {
    const tracks = (this._probeResult && this._probeResult.audioTracks) || [];
    if (this.isLive || tracks.length < 2) return [];
    return tracks.map((t) => ({ id: t.index, label: trackLabel(t, 'audio'), lang: t.lang || '', active: t.index === (this._audioIndex || 0) }));
  }

  // Plays on from the same moment with another of the film's audio tracks.
  selectAudio(index) {
    const tracks = (this._probeResult && this._probeResult.audioTracks) || [];
    const track = tracks.find((t) => t.index === index);
    if (!track || index === (this._audioIndex || 0) || !this._originalUrl) return;
    this._audioIndex = index;
    this._baseMode = audioNeedsFix(track.codec) ? 'audiofix' : 'copy';
    const reencoding = /^scale\d+$/.test(this._lastMode) || this._lastMode === 'transcode';
    const mode = reencoding ? this._lastMode : this._baseMode;
    const at = this.getDisplayCurrentTime();
    console.log(`[player] audio -> track ${index} (${track.lang || '?'} ${track.codec}) mode=${mode} at ${at.toFixed(1)}s`);
    this._clearStallTimer();
    this._dataReceived = false;
    this._notify('buffering', 'Switching audio...');
    this._playProxy(this._originalUrl, this._playToken, mode, at);
  }

  // ---- Subtitles ----

  getSubtitleOptions() {
    const tracks = ((this._probeResult && this._probeResult.subtitleTracks) || []).filter((t) => t.text);
    if (this.isLive || !tracks.length) return [];
    return [
      { id: -1, label: 'Off', active: this._subIndex < 0 },
      ...tracks.map((t) => ({ id: t.index, label: trackLabel(t, 'sub'), lang: t.lang || '', active: t.index === this._subIndex }))
    ];
  }

  // Cues come from the proxy as ffmpeg reaches them (see /subs in main.js)
  // and are kept here too, so they can be laid out again whenever the
  // timeline mapping changes.
  selectSubtitle(index) {
    this._subIndex = index;
    this._subCues = [];
    this._subAfter = 0;
    this._clearSubtitleTrack();
    if (this._subTimer) { clearInterval(this._subTimer); this._subTimer = null; }
    const track = this._subtitleTrack();
    if (index < 0 || !this._originalUrl) { track.mode = 'disabled'; return; }
    track.mode = 'showing';
    const token = this._playToken;
    const url = this._originalUrl;
    const tick = () => {
      if (token !== this._playToken || this._subIndex !== index || !this.proxyBase) return;
      fetch(`${this.proxyBase}/subs?url=${encodeURIComponent(url)}&sub=${index}&after=${this._subAfter}`, { cache: 'no-store' })
        .then((r) => r.json())
        .then((d) => {
          if (token !== this._playToken || this._subIndex !== index || !d) return;
          const fresh = d.cues || [];
          this._subAfter += fresh.length;
          this._subCues.push(...fresh);
          const offset = this._mse ? 0 : (this._seekOffset || 0);
          if (offset !== this._subCueOffset) {
            this._clearSubtitleTrack();
            this._addCues(this._subCues, offset);
          } else {
            this._addCues(fresh, offset);
          }
        })
        .catch(() => {});
    };
    tick();
    this._subTimer = setInterval(tick, 1500);
  }

  _subtitleTrack() {
    if (!this._textTrack) this._textTrack = this.video.addTextTrack('subtitles', 'Subtitles', 'und');
    return this._textTrack;
  }

  _clearSubtitleTrack() {
    const track = this._textTrack;
    if (track && track.cues) {
      for (let i = track.cues.length - 1; i >= 0; i--) { try { track.removeCue(track.cues[i]); } catch {} }
    }
    this._subCueOffset = undefined;
  }

  _addCues(list, offset) {
    const track = this._subtitleTrack();
    this._subCueOffset = offset;
    for (const [start, end, text] of list) {
      if (end - offset <= 0) continue;
      try {
        const cue = new VTTCue(Math.max(0, start - offset), end - offset, text);
        // Sit above the control bar rather than behind it.
        cue.snapToLines = false;
        cue.line = 86;
        cue.lineAlign = 'end';
        track.addCue(cue);
      } catch { /* malformed cue */ }
    }
  }

  _playDirect(url, token) {
    this._stage = 'direct';
    this._directStartedAt = Date.now();
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
    // Downloaded files always go through the proxy too: same audio-track,
    // subtitle and quality handling as when streaming.
    if (knownIncompatible.some((ext) => lower.endsWith(ext)) || /^file:/i.test(url)) {
      if (!this.proxyBase) {
        setTimeout(() => { if (token === this._playToken) this._playDirect(url, token); }, 150);
        return;
      }
      this._playProxy(url, token, 'copy', this._startAt);
      return;
    }

    console.log('[player] trying native <video> playback');
    if (this._startAt > 0) {
      const startAt = this._startAt;
      const jump = () => {
        this.video.removeEventListener('loadedmetadata', jump);
        if (token !== this._playToken) return;
        const d = this.video.duration;
        if (isFinite(d) && startAt < d * 0.97) { try { this.video.currentTime = startAt; } catch {} }
      };
      this.video.addEventListener('loadedmetadata', jump);
    }
    this.video.src = url;
    this.video.play().catch(() => {});
    this._armStallTimer(token, 5000);
  }

  _playHls(url, token) {
    if (window.Hls && window.Hls.isSupported()) {
      // Tuned for IPTV rather than low latency. Holding playback only three
      // seconds behind the live edge, with segments that are often ten
      // seconds long, left no room at all: every slightly late segment meant
      // a rebuffer, and the latency chasing kept jumping forward into more
      // of them. Sitting a few segments back plays smoothly.
      this.hls = new window.Hls({
        enableWorker: true,
        lowLatencyMode: false,
        liveSyncDurationCount: 3,
        liveMaxLatencyDurationCount: 12,
        maxLiveSyncPlaybackRate: 1,
        maxBufferLength: 30,
        maxMaxBufferLength: 60,
        backBufferLength: 30,
        maxBufferHole: 1,
        nudgeMaxRetry: 10,
        startFragPrefetch: true,
        manifestLoadingTimeOut: 8000,
        manifestLoadingMaxRetry: 2,
        manifestLoadingRetryDelay: 500,
        levelLoadingTimeOut: 8000,
        levelLoadingMaxRetry: 3,
        levelLoadingRetryDelay: 500,
        fragLoadingTimeOut: 15000,
        fragLoadingMaxRetry: 4,
        fragLoadingRetryDelay: 500
      });
      const hls = this.hls;
      hls.loadSource(url);
      hls.attachMedia(this.video);
      hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
        if (token !== this._playToken || hls !== this.hls) return;
        this._applyHlsQuality();
        this.video.play().catch(() => {});
        this._armFreezeWatchdog(token);
        this._armAudioWatchdog(token);
      });
      hls.on(window.Hls.Events.FRAG_BUFFERED, () => {
        if (token !== this._playToken || hls !== this.hls) return;
        this._hlsNetworkErrors = 0;
      });
      // Many IPTV channels carry AC3/E-AC3 audio, which Chromium's
      // MediaSource has no decoder for at all — the picture plays perfectly
      // and the sound is just silently dropped, with hls.js never raising
      // any error about it. The manifest usually doesn't declare a codec
      // either, so this is the first point the real one is known: the
      // remuxed codec string, right before hls.js creates the audio source
      // buffer. If the browser can't decode it, jump to the proxy (which
      // re-encodes to AAC) before any silent playback starts.
      hls.on(window.Hls.Events.BUFFER_CODECS, (_e, tracks) => {
        if (token !== this._playToken || hls !== this.hls) return;
        const audio = tracks && tracks.audio;
        if (!audio || !audio.codec) return;
        const mime = `audio/mp4; codecs="${audio.codec}"`;
        if (!window.MediaSource.isTypeSupported(mime)) {
          console.log(`[player] live audio codec unsupported (${mime}) — switching to proxy`);
          this._teardownEngines();
          this._notify('buffering', 'Fixing audio...');
          this._playProxy(this._originalUrl, token, 'audiofix', this._startAt);
        }
      });
      // Generous enough for a slow manifest (manifestLoadingTimeOut is 8s,
      // and can retry once), but a channel that's still silent after this —
      // playlist loaded but every fragment keeps failing, as a dead channel
      // does — falls back to the proxy instead of sitting frozen for longer.
      this._armStallTimer(token, 11000);
      hls.on(window.Hls.Events.ERROR, (_e, data) => {
        if (token !== this._playToken || hls !== this.hls || !data.fatal) return;
        switch (data.type) {
          case window.Hls.ErrorTypes.NETWORK_ERROR: {
            // hls.js has already retried internally by the time an error is
            // fatal. A channel that had been playing and just hiccuped is
            // worth persisting on — kept spaced out so a provider blip
            // doesn't turn into a hammering loop. One that never connected
            // at all is more likely genuinely off the air: give up sooner
            // instead of leaving the screen spinning for a minute.
            this._hlsNetworkErrors = (this._hlsNetworkErrors || 0) + 1;
            const everConnected = this._dataReceived;
            const limit = everConnected ? 6 : 2;
            if (this._hlsNetworkErrors > limit) {
              this._fallback(token, 'Reconnecting to the channel...');
              return;
            }
            this._notify('buffering', 'Reconnecting...');
            clearTimeout(this._hlsRetryTimer);
            const backoff = everConnected ? Math.min(5000, 800 * this._hlsNetworkErrors) : 600;
            this._hlsRetryTimer = setTimeout(() => {
              if (token === this._playToken && hls === this.hls) hls.startLoad();
            }, backoff);
            break;
          }
          case window.Hls.ErrorTypes.MEDIA_ERROR:
            this._hlsMediaErrors = (this._hlsMediaErrors || 0) + 1;
            if (this._hlsMediaErrors > 3) {
              this._fallback(token, 'Trying a compatible format...');
              return;
            }
            this._notify('buffering');
            if (this._hlsMediaErrors === 2) hls.swapAudioCodec();
            hls.recoverMediaError();
            break;
          default:
            this._fallback(token, 'This stream is unavailable.');
            break;
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
        enableStashBuffer: true,
        // A small stash empties fast on an HD channel the moment the network
        // dips even briefly — that's what a silent freeze (no error, no
        // message, picture just stops) looks like. A bigger cushion absorbs
        // those blips before playback ever runs dry.
        stashInitialSize: 4 * 1024 * 1024,
        liveBufferLatencyChasing: false,
        lazyLoad: false,
        autoCleanupSourceBuffer: true
      });
      const engine = this.mpegts;
      engine.attachMediaElement(this.video);
      engine.load();
      engine.play().catch(() => {});
      engine.on(window.mpegts.Events.ERROR, () => {
        if (token !== this._playToken || engine !== this.mpegts) return;
        this._fallback(token, 'This channel format is unsupported.');
      });
      this._armStallTimer(token, 12000);
      this._armFreezeWatchdog(token);
      this._armAudioWatchdog(token);
      return;
    }
    this._fallback(token, null);
  }

  _onVideoError() {
    if (this._seeking) return;
    const token = this._playToken;
    const err = this.video.error;

    // hls.js briefly touches the video element while attachMedia()/loadSource()
    // are still wiring things up (before it has a real MediaSource attached),
    // and that transient state alone can fire a native `error` event with no
    // MediaError at all (err=null) — completely harmless, hls.js recovers on
    // its own a moment later. Without this guard every single live channel
    // was treating that as a genuine failure and immediately abandoning the
    // fast native/hls.js path for the ffmpeg proxy, which always works but is
    // much slower to start — every channel paid that penalty on every play,
    // not just channels that were actually having trouble.
    if (this._stage === 'direct' && !err && !this._mse && Date.now() - (this._directStartedAt || 0) < 1500) {
      return;
    }

    // Under MediaSource the element itself isn't fetching anything.
    if (this._mse) {
      if (err) {
        // A decode/demux failure kills the MediaSource for good; waiting
        // would only leave the spinner up forever.
        console.log(`[player] MSE media error ${err.code}: ${err.message || ''}`);
        this._fallbackFromMse(this._mseBuildUrl, token, `decode error ${err.code} ${err.message || ''}`);
        return;
      }
      if (this._dataReceived) return;
      // No data for a long while: re-open at the same point a couple of
      // times before giving up on MediaSource.
      this._mseStalls++;
      if (this._mseStalls > 2) {
        this._fallbackFromMse(this._mseBuildUrl, token, 'no data');
        return;
      }
      console.log(`[player] MSE stalled — reopening at ${this.video.currentTime.toFixed(1)}s`);
      this._mse.reopenAt(this.video.currentTime);
      this._armStallTimer(token, 45000);
      return;
    }

    if (this._dataReceived) return;
    console.log(`[player] _onVideoError stage=${this._stage} err=${err ? err.code : 'none'}`);
    const resumeAt = this._stage.startsWith('proxy') ? this.getDisplayCurrentTime() : this._startAt;
    // A live channel that fails to open at all is usually genuinely off the
    // air or the provider is refusing the connection — every mode (copy,
    // audiofix, transcode) opens that exact same source first, so cycling
    // through all three just repeats the same failure three times over,
    // which is what left a dead channel spinning for 20+ seconds before
    // finally giving up. One proxy attempt is enough for live; VOD still
    // gets the full ladder since a real audio-codec mismatch is common there
    // and each mode really does behave differently.
    if (this._stage === 'direct') {
      this._fallback(token, 'Trying a compatible format...');
    } else if (this._stage === 'proxy-copy' && !this.isLive) {
      this._dataReceived = false;
      this._playProxy(this._originalUrl, token, 'audiofix', resumeAt);
    } else if (this._stage === 'proxy-audiofix') {
      this._dataReceived = false;
      this._playProxy(this._originalUrl, token, 'transcode', resumeAt);
    } else {
      this._notify('error:final', this.isLive
        ? 'This channel is unavailable right now — try another.'
        : 'Stream could not be played. The server may be down or blocking connections.');
    }
  }

  _fallback(token, message, skipCopy = false) {
    if (token !== this._playToken) return;
    this._teardownEngines();
    if (this._stage === 'direct' && !skipCopy) {
      // Stop the element's own request first: the probe that follows needs
      // the provider connection it is holding.
      this.video.removeAttribute('src');
      this.video.load();
      if (message) this._notify('buffering', message);
      // Same one-connection hand-off gap as _armAudioWatchdog below: the
      // provider account can take a moment to notice hls.js/mpegts.js let go
      // of its connection. Asking for the proxy's connection immediately
      // sometimes got refused — which, for a live channel, meant the single
      // permitted proxy attempt failed for timing reasons having nothing to
      // do with the channel, and it was reported dead ("channel unavailable")
      // even though it plays fine everywhere else (confirmed against the
      // Android app, which connects directly with no proxy hand-off at all).
      setTimeout(() => {
        if (token !== this._playToken) return;
        this._playProxy(this._originalUrl, token, 'copy', this._startAt);
      }, 700);
    } else if ((this._stage === 'proxy-copy' || skipCopy) && !this.isLive) {
      this._playProxy(this._originalUrl, token, 'audiofix', 0);
    } else if (this._stage === 'proxy-audiofix') {
      this._playProxy(this._originalUrl, token, 'transcode', 0);
    } else {
      this._notify('error:final', message || 'This stream could not be played.');
    }
  }

  // MediaSource needs a known running time to be worth using — that's what
  // lets it declare a real seek bar and jump anywhere. Live streams keep the
  // plain path, as does anything we couldn't probe.
  _shouldUseMse() {
    return !this.isLive
      && !this._mseDisabled
      && !!this._fixedDuration
      && typeof window.MseVodStreamer !== 'undefined'
      && window.MseVodStreamer.isSupported();
  }

  _startMse(buildUrl, token, finalMode) {
    if (this._mse) { try { this._mse.destroy(); } catch {} this._mse = null; }
    const streamer = new window.MseVodStreamer(this.video);
    this._mse = streamer;
    this._mseBuildUrl = buildUrl;
    this._mseStalls = 0;
    // MediaSource carries the whole timeline itself, so currentTime is
    // already the real position — no per-stream offset to add back on.
    this._seekOffset = 0;

    // A streamer that has already been replaced must not touch playback:
    // its late errors would otherwise tear down whatever is playing now.
    const isCurrent = () => token === this._playToken && this._mse === streamer;

    streamer.onFirstData = () => {
      if (!isCurrent()) return;
      this._dataReceived = true;
      this._mseStalls = 0;
      this._clearStallTimer();
    };
    streamer.onFatal = (err) => {
      if (!isCurrent()) return;
      console.log(`[player] MSE failed (${err && err.message}) — falling back`);
      this._fallbackFromMse(buildUrl, token, err && err.message);
    };

    const startAt = this._pendingSeek || 0;
    this._mseStarting = true;
    streamer.start({ buildUrl, duration: this._fixedDuration, startAt })
      .then(() => {
        if (!isCurrent()) return;
        console.log(`[player] MSE playback started at ${startAt.toFixed(1)}s`);
        if (startAt > 0) { try { this.video.currentTime = startAt; } catch {} }
        this._mseStarting = false;
        this.video.play().catch(() => {});
      })
      .catch((err) => {
        if (!isCurrent()) return;
        this._mseStarting = false;
        console.log(`[player] MSE setup failed (${err && err.message}) — falling back`);
        this._fallbackFromMse(buildUrl, token, err && err.message);
      });

    this._armStallTimer(token, 45000);
  }

  // What to do when MediaSource can't carry on. A stream the browser can't
  // decode moves to the next, more compatible mode (still with MediaSource);
  // anything else — the connection, the proxy — drops to a plain <video>
  // stream in the same mode. Either way playback continues from where it was.
  _fallbackFromMse(buildUrl, token, reason) {
    if (token !== this._playToken) return;
    const at = this._mse ? (this.video.currentTime || this._pendingSeek || 0) : (this._pendingSeek || 0);
    if (this._mse) { try { this._mse.destroy(); } catch {} this._mse = null; }
    this._dataReceived = false;
    const undecodable = /unsupported|no decodable header|decode error/i.test(reason || '');
    if (undecodable) {
      // Audio is the usual culprit, and audiofix keeps the original picture;
      // a video codec this machine can't decode (HEVC on some GPUs) needs the
      // full re-encode straight away.
      const videoCodec = ((this._probeResult && this._probeResult.videoCodec) || '').toLowerCase();
      const videoOk = !videoCodec || videoCodec === 'h264';
      const next = this._lastMode === 'copy' && videoOk ? 'audiofix' : this._lastMode === 'transcode' ? null : 'transcode';
      if (next) {
        console.log(`[player] ${this._lastMode} can't be decoded here — switching to ${next} at ${at.toFixed(1)}s`);
        this._notify('buffering', 'Trying a compatible format...');
        this._playProxy(this._originalUrl, token, next, at);
        return;
      }
    }
    this._mseDisabled = true;
    this._seekOffset = at;
    this._pendingSeek = at;
    this.video.src = (buildUrl || this._mseBuildUrl)(at, false);
    this.video.play().then(() => {
      if (token === this._playToken) this._notify('playing');
    }).catch(() => {});
    this._armStallTimer(token, at > 0 ? 120000 : 40000);
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
    this._teardownEngines();
    const stageFor = (m) => (m === 'copy' ? 'proxy-copy' : m === 'audiofix' ? 'proxy-audiofix' : 'proxy-transcode');
    this._stage = stageFor(mode);
    this._lastMode = mode;
    // The proxy restarts ffmpeg at seekSec and the resulting stream begins
    // at timestamp 0, so this offset is what maps it back onto the real
    // timeline for display.
    this._seekOffset = seekSec || 0;
    this._pendingSeek = seekSec || 0;
    this._dataReceived = false;
    this._notify('buffering', seekSec > 0 ? 'Loading...' : 'Preparing stream...');

    const sid = this._sid(token);
    const startStream = (finalMode) => {
      if (token !== this._playToken) return;
      this._stage = stageFor(finalMode);
      this._lastMode = finalMode;
      // dur lets the proxy work out how many bytes into the cache file the
      // seek position lands before handing it to ffmpeg.
      const audio = this._audioIndex || 0;
      const buildUrl = (sec, forMse = true) => `${this.proxyBase}/stream?url=${encodeURIComponent(originalUrl)}`
        + `&mode=${finalMode}&live=${this.isLive ? '1' : '0'}&seek=${sec}&dur=${this._fixedDuration || 0}`
        + `&audio=${audio}&sid=${sid}&mse=${forMse ? 1 : 0}&t=${Date.now()}`;
      console.log(`[player] _playProxy mode=${finalMode} seek=${this._pendingSeek.toFixed(1)}`);

      if (this._shouldUseMse()) {
        this._startMse(buildUrl, token, finalMode);
        return;
      }
      this._seekOffset = this._pendingSeek;
      this.video.src = buildUrl(this._seekOffset, false);
      this.video.play().then(() => {
        if (token === this._playToken) this._notify('playing');
      }).catch(() => {});
      // A live channel that never connects should fail fast, not sit spinning
      // for a minute+ — 12s per attempt is plenty for the proxy to report
      // ffmpeg couldn't open the source.
      const timeout = this.isLive ? 12000 : (this._seekOffset > 0 ? 120000 : 40000);
      this._armStallTimer(token, timeout);
      if (this.isLive && finalMode === 'copy') this._armAudioWatchdog(token);
    };

    // The probe costs a couple of seconds but earns them back twice over: it
    // gives the running time MediaSource needs to offer a real seek bar, and
    // it picks the right mode up front instead of starting a copy that has
    // to be thrown away when the audio turns out to be undecodable
    // (AC3/EAC3/DTS/TrueHD). It runs once per playback; the proxy remembers
    // the answer for reopening the same title.
    if (!this.isLive && !this._probeResult) {
      fetch(`${this.proxyBase}/probe?url=${encodeURIComponent(originalUrl)}&sid=${sid}`, { cache: 'no-store' })
        .then((r) => r.json())
        .then((d) => {
          if (token !== this._playToken) return;
          this._probeResult = d || {};
          if (d && d.duration) this._fixedDuration = d.duration;
          this._sourceHeight = (d && d.height) || 0;
          const audioTracks = (d && d.audioTracks) || [];
          const langOf = (t) => (t.lang || '').toLowerCase();
          const preferred = this.preferredAudioLang
            && audioTracks.find((t) => sameLanguage(langOf(t), this.preferredAudioLang));
          const chosenAudio = preferred || audioTracks.find((t) => t.default) || audioTracks[0] || null;
          this._audioIndex = chosenAudio ? chosenAudio.index : 0;
          const audio = chosenAudio ? chosenAudio.codec : (d && d.audioCodec);
          this._baseMode = audioNeedsFix(audio) ? 'audiofix' : 'copy';

          // Subtitles come back on in the language last chosen, when this
          // film has it.
          const textSubs = ((d && d.subtitleTracks) || []).filter((t) => t.text);
          if (this.preferredSubtitleLang) {
            const sub = textSubs.find((t) => sameLanguage(langOf(t), this.preferredSubtitleLang) && !t.forced)
              || textSubs.find((t) => sameLanguage(langOf(t), this.preferredSubtitleLang));
            if (sub) setTimeout(() => { if (token === this._playToken) this.selectSubtitle(sub.index); }, 0);
          }

          // A resume point in the last few percent means the film was
          // finished — start it over instead of opening on the credits.
          if (this._fixedDuration && this._pendingSeek >= this._fixedDuration * 0.97) {
            this._pendingSeek = 0;
            this._seekOffset = 0;
          }

          let chosen = mode;
          if (mode === 'copy') {
            // A saved preference below this video's own resolution starts it
            // scaled down; at or above it (or "auto") it plays as-is.
            const pref = parseInt(this.quality, 10);
            chosen = pref && this._sourceHeight && pref < this._sourceHeight - 20 ? `scale${pref}` : this._baseMode;
          }
          console.log(`[player] probe: ${this._sourceHeight || '?'}p audio=${audio || 'unknown'} dur=${(d && d.duration) || '?'} -> ${chosen}`);
          startStream(chosen);
        })
        .catch(() => { this._probeResult = {}; startStream(mode); });
      return;
    }

    // Undecodable audio needs audiofix whichever way playback got here.
    if (mode === 'copy' && this._baseMode === 'audiofix') {
      startStream('audiofix');
      return;
    }

    startStream(mode);
  }

  // Returns the state the press is aiming for, so the button can redraw on
  // the click rather than waiting for the element's own event.
  togglePlayPause() {
    const wasPaused = this.video.paused;
    if (wasPaused) this.video.play().catch(() => {});
    else this.video.pause();
    return { playing: wasPaused };
  }

  seekTo(targetSeconds) {
    const dur = this.getDisplayDuration();
    let seconds = Math.max(0, targetSeconds);
    if (isFinite(dur) && dur > 0) seconds = Math.min(seconds, Math.max(0, dur - 0.5));

    if (this._stage === 'direct') {
      if (isFinite(this.video.duration)) this.video.currentTime = seconds;
      return;
    }

    // With MediaSource the whole timeline belongs to us: anything already
    // appended is an instant jump, and anything else re-opens the stream at
    // that point and splices it in — no element teardown either way.
    if (this._mse) {
      const { instant } = this._mse.seekTo(seconds);
      if (!instant) {
        this._dataReceived = false;
        this._pendingSeek = seconds;
        this._notify('buffering', 'Seeking...');
        this._armStallTimer(this._playToken, 45000);
      }
      return;
    }

    if (this._stage.startsWith('proxy')) {
      const relativeTarget = seconds - this._seekOffset;

      // Anything the browser already holds can be jumped to instantly.
      let inBuffer = false;
      for (let i = 0; i < this.video.buffered.length; i++) {
        if (relativeTarget >= this.video.buffered.start(i) - 1 && relativeTarget <= this.video.buffered.end(i) + 1) {
          inBuffer = true;
          break;
        }
      }

      // Nothing past the buffered edge can be reached by assigning
      // currentTime: the proxy serves VOD as a non-seekable stream, so the
      // player's own idea of the duration only covers what has arrived, and
      // it silently drops a seek beyond that (landing back near the start).
      // Those have to go through a restart at the target instead.
      if (inBuffer) {
        this._seeking = true;
        try { this.video.currentTime = relativeTarget; } catch {}
        const clearSeeking = () => {
          this._seeking = false;
          this.video.removeEventListener('seeked', clearSeeking);
          this.video.removeEventListener('playing', clearSeeking);
          this.video.removeEventListener('pause', clearSeeking);
        };
        this.video.addEventListener('seeked', clearSeeking);
        this.video.addEventListener('playing', clearSeeking);
        this.video.addEventListener('pause', clearSeeking);
        setTimeout(clearSeeking, 2000);
        return;
      }

      // Outside the browser's buffer the stream has to be restarted at the
      // target, since the proxy serves VOD as a non-seekable stream.
      console.log(`[player] seekTo: not buffered, restarting at ${seconds.toFixed(1)}s`);
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

// Chromium plays AAC, MP3, Opus and FLAC from MP4; anything else (AC3,
// E-AC3, DTS, TrueHD, MP2, PCM, Vorbis...) is re-encoded to AAC.
function audioNeedsFix(codec) {
  if (!codec) return false;
  return !['aac', 'mp3', 'opus', 'flac'].includes(String(codec).toLowerCase());
}

// Containers use ISO 639-2 codes, and a few languages have two of them
// ("ger" and "deu"); the Intl names only know one.
const LANGUAGE_ALIASES = {
  ger: 'deu', fre: 'fra', chi: 'zho', cze: 'ces', dut: 'nld', gre: 'ell', per: 'fas', rum: 'ron',
  slo: 'slk', alb: 'sqi', arm: 'hye', baq: 'eus', bur: 'mya', geo: 'kat', ice: 'isl', mac: 'mkd',
  mao: 'mri', may: 'msa', tib: 'bod', wel: 'cym'
};
function canonicalLanguage(code) {
  const c = String(code || '').toLowerCase().trim();
  return LANGUAGE_ALIASES[c] || c;
}
function sameLanguage(a, b) {
  const x = canonicalLanguage(a);
  const y = canonicalLanguage(b);
  if (!x || !y || x === 'und' || y === 'und') return false;
  return x === y || languageName(x) === languageName(y);
}
function languageName(code) {
  const c = canonicalLanguage(code);
  if (!c || c === 'und' || c === 'unk' || c === 'mis') return '';
  try {
    const name = new Intl.DisplayNames(['en'], { type: 'language' }).of(c);
    if (name && name.toLowerCase() !== c) return name;
  } catch { /* not a code Intl knows */ }
  return c.toUpperCase();
}
function trackLabel(t, kind) {
  const name = languageName(t.lang);
  const title = String(t.title || '').trim();
  let label = name || title || `Track ${t.index + 1}`;
  if (name && title && !title.toLowerCase().includes(name.toLowerCase())) label += ` · ${title}`;
  if (kind === 'audio') {
    const ch = t.channels >= 6 ? '5.1' : t.channels === 2 ? 'Stereo' : t.channels === 1 ? 'Mono' : '';
    if (ch) label += ` (${ch})`;
  }
  if (kind === 'sub' && t.forced) label += ' (forced)';
  return label;
}

function qualityLabel(height) {
  if (height >= 2100) return '4K';
  if (height >= 1400) return '1440p';
  return `${height}p`;
}

window.PlayerController = PlayerController;
