// MediaSource-based VOD playback.
//
// Handing the proxy URL straight to <video> makes the browser treat it as a
// non-seekable stream: it only ever knows about the slice of timeline that
// has arrived, refuses to seek past it, and stops reading ahead once it
// believes it has the whole thing. Every nudge forward then costs a full
// stream restart.
//
// Feeding the same fragmented MP4 through MediaSource instead puts the
// timeline under our control: the real running time is declared up front,
// so the seek bar is honest and the player will seek anywhere; data already
// appended can be jumped to with no fetch at all; and a jump outside it
// re-opens the stream at that point and splices it onto the timeline with
// timestampOffset, without tearing the element down.

// How much fetched-but-not-yet-appended data may pile up before reading
// from the network pauses.
const MSE_MAX_QUEUED_BYTES = 8 * 1024 * 1024;

class MseVodStreamer {
  constructor(video) {
    this.video = video;
    this.mediaSource = null;
    this.sourceBuffer = null;
    this.objectUrl = null;
    this.duration = 0;
    this.buildUrl = null;
    this.onFatal = null;
    this.onFirstData = null;

    this._generation = 0;      // invalidates in-flight readers after a seek
    this._controller = null;   // aborts the request of the stream being replaced
    this._queue = [];          // Uint8Array chunks, and { reset: offset } markers
    this._queuedBytes = 0;
    this._destroyed = false;
    this._codecs = null;
    this._loadStart = 0;       // timeline position the current stream began at
    this._streamEnded = false; // current stream's body is fully read
    this._reopenAttempts = 0;
    this._lastReached = 0;
    this._retryTimer = null;
    this._quotaTimer = null;
    this._onUpdateEnd = () => this._pump();
  }

  static isSupported() {
    return typeof window.MediaSource !== 'undefined'
      && typeof window.MediaSource.isTypeSupported === 'function';
  }

  // buildUrl(seekSeconds) -> proxy URL that streams fragmented MP4 whose
  // timestamps restart at zero.
  start({ buildUrl, duration, startAt = 0 }) {
    this.buildUrl = buildUrl;
    this.duration = duration > 0 ? duration : 0;

    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (err) => { if (!settled) { settled = true; reject(err); } };
      const ok = () => { if (!settled) { settled = true; resolve(); } };

      try {
        this.mediaSource = new window.MediaSource();
      } catch (err) { fail(err); return; }

      this.objectUrl = URL.createObjectURL(this.mediaSource);
      this.mediaSource.addEventListener('sourceopen', () => {
        if (this._destroyed) return;
        try {
          if (this.duration > 0) this.mediaSource.duration = this.duration;
        } catch { /* a duration we can't set just means a less useful seek bar */ }
        this._loadFrom(startAt).then(ok).catch(fail);
      }, { once: true });

      this.video.src = this.objectUrl;
    });
  }

  isBuffered(sec) {
    const b = this.sourceBuffer && this.sourceBuffer.buffered;
    if (!b) return false;
    for (let i = 0; i < b.length; i++) {
      if (sec >= b.start(i) && sec <= b.end(i) - 0.5) return true;
    }
    return false;
  }

  // Instant when the position is already in the buffer; otherwise the stream
  // is re-opened at that point and spliced in.
  seekTo(sec) {
    const target = Math.max(0, this.duration > 0 ? Math.min(sec, this.duration - 1) : sec);
    if (this.isBuffered(target)) {
      try { this.video.currentTime = target; } catch {}
      return { instant: true };
    }
    this._restoreDuration();
    try { this.video.currentTime = target; } catch {}
    this._reopenAttempts = 0;
    this._open(target);
    return { instant: false };
  }

  // Starts reading again at `sec`, e.g. after the player noticed nothing
  // has arrived for a long time.
  reopenAt(sec) {
    if (this._destroyed) return;
    this._reopenAttempts = 0;
    this._open(Math.max(0, sec));
  }

  destroy() {
    this._destroyed = true;
    this._generation++;
    if (this._controller) { try { this._controller.abort(); } catch {} this._controller = null; }
    clearTimeout(this._retryTimer);
    clearTimeout(this._quotaTimer);
    this._queue = [];
    this._queuedBytes = 0;
    if (this.sourceBuffer) {
      try { this.sourceBuffer.removeEventListener('updateend', this._onUpdateEnd); } catch {}
      try { this.sourceBuffer.abort(); } catch {}
    }
    if (this.mediaSource && this.mediaSource.readyState === 'open') {
      try { this.mediaSource.endOfStream(); } catch {}
    }
    if (this.objectUrl) {
      try { URL.revokeObjectURL(this.objectUrl); } catch {}
      this.objectUrl = null;
    }
    this.sourceBuffer = null;
    this.mediaSource = null;
  }

  // Opens a stream and, when that fails outright (the proxy was busy handing
  // over the connection, a network blip), tries again a few times before
  // giving up on MediaSource altogether.
  _open(seekSec, attempt = 0) {
    const gen = this._generation + 1;
    this._loadFrom(seekSec).catch((err) => {
      if (this._destroyed || gen !== this._generation) return;
      if (attempt < 3) {
        console.log(`[mse] reopen at ${seekSec.toFixed(1)}s failed (${err && err.message}) — retrying`);
        clearTimeout(this._retryTimer);
        this._retryTimer = setTimeout(() => {
          if (!this._destroyed && gen === this._generation) this._open(seekSec, attempt + 1);
        }, 600 * (attempt + 1));
      } else if (this.onFatal) {
        this.onFatal(err);
      }
    });
  }

  async _loadFrom(seekSec) {
    const gen = ++this._generation;
    // Cancel the request being replaced, so the proxy lets go of its
    // connection to the provider straight away instead of whenever the next
    // chunk happens to arrive.
    if (this._controller) { try { this._controller.abort(); } catch {} }
    const controller = new AbortController();
    this._controller = controller;
    this._queue = [];
    this._queuedBytes = 0;
    this._streamEnded = false;
    clearTimeout(this._retryTimer);
    const stale = () => gen !== this._generation || this._destroyed;

    const res = await fetch(this.buildUrl(seekSec), { signal: controller.signal, cache: 'no-store' });
    if (stale()) { try { controller.abort(); } catch {} return; }
    if (!res.ok || !res.body) throw new Error(`stream request failed: ${res.status}`);
    // Where this stream's data actually sits on the film's timeline. A copied
    // stream starts at the keyframe before the requested point; placing it
    // at the requested point instead made the picture run a few seconds late.
    const reported = parseFloat(res.headers.get('X-Media-Start'));
    const placeAt = isFinite(reported) && reported >= 0 && reported <= seekSec + 1 ? reported : seekSec;

    const reader = res.body.getReader();
    let sawData = false;
    const gotData = () => {
      if (sawData) return;
      sawData = true;
      if (this.onFirstData) this.onFirstData();
    };

    if (!this.sourceBuffer) {
      // The first response also tells us which codecs to declare.
      const pending = [];
      for (;;) {
        const { value, done } = await reader.read();
        if (stale()) { try { reader.cancel(); } catch {} return; }
        if (done) throw new Error('stream ended before the header arrived');
        pending.push(value);
        const head = concatChunks(pending);
        const codecs = parseCodecs(head);
        if (!codecs) {
          if (head.length > 2 * 1024 * 1024) throw new Error('no decodable header in the first 2MB');
          continue;
        }
        const mime = pickSupportedMime(codecs);
        if (!mime) throw new Error(`unsupported: video/mp4; codecs="${codecs}"`);
        this._codecs = mime;
        console.log(`[mse] codecs=${mime}`);
        this.sourceBuffer = this.mediaSource.addSourceBuffer(mime);
        this.sourceBuffer.mode = 'segments';
        this.sourceBuffer.addEventListener('updateend', this._onUpdateEnd);
        this.sourceBuffer.addEventListener('error', () => {
          const err = this.video.error;
          console.log(`[mse] sourcebuffer error, video.error=${err ? err.code : 'none'}`);
        });
        this._enqueue({ reset: placeAt });
        this._enqueue(head);
        gotData();
        break;
      }
    } else {
      // Re-opened after a seek: the new stream carries its own header. The
      // marker resets the parser (the previous stream may have stopped in the
      // middle of a fragment) and places the new one at the right point.
      this._enqueue({ reset: placeAt });
    }

    // Drain the rest in the background; a newer seek supersedes it.
    (async () => {
      try {
        for (;;) {
          while (this._queuedBytes > MSE_MAX_QUEUED_BYTES && !stale()) {
            await new Promise((r) => setTimeout(r, 150));
          }
          if (stale()) { try { reader.cancel(); } catch {} return; }
          const { value, done } = await reader.read();
          if (stale()) { try { reader.cancel(); } catch {} return; }
          if (done) { this._markEnded(gen); return; }
          gotData();
          this._enqueue(value);
        }
      } catch (err) {
        if (stale()) return;
        console.log(`[mse] stream interrupted: ${err && err.message}`);
        this._markEnded(gen);
      }
    })();
  }

  _enqueue(item) {
    this._queue.push(item);
    if (item instanceof Uint8Array) this._queuedBytes += item.length;
    this._pump();
  }

  _markEnded(gen) {
    if (gen !== this._generation || this._destroyed) return;
    this._streamEnded = true;
    this._pump();
  }

  _pump() {
    if (this._destroyed || !this.sourceBuffer) return;
    const sb = this.sourceBuffer;
    const ms = this.mediaSource;
    if (sb.updating || !ms || (ms.readyState !== 'open' && ms.readyState !== 'ended')) return;

    while (this._queue.length && !(this._queue[0] instanceof Uint8Array)) {
      const marker = this._queue[0];
      try { if (ms.readyState === 'open') sb.abort(); } catch {}
      try {
        sb.timestampOffset = marker.reset;
      } catch {
        clearTimeout(this._retryTimer);
        this._retryTimer = setTimeout(() => this._pump(), 50);
        return;
      }
      this._queue.shift();
      this._loadStart = marker.reset;
      this._lastReached = marker.reset;
      this._restoreDuration();
    }

    if (!this._queue.length) {
      if (this._streamEnded) this._finishStream();
      return;
    }

    const chunk = this._queue[0];
    try {
      sb.appendBuffer(chunk);
      this._queue.shift();
      this._queuedBytes -= chunk.length;
    } catch (err) {
      if (err && err.name === 'QuotaExceededError') {
        // Buffer is full. Drop what's furthest from the playhead; if nothing
        // can go yet, wait for playback to move on and try again.
        if (!this._evict()) {
          clearTimeout(this._quotaTimer);
          this._quotaTimer = setTimeout(() => this._pump(), 1000);
        }
        return;
      }
      if (this.onFatal) this.onFatal(err);
    }
  }

  // How far the current stream has filled the timeline.
  _reachedEnd() {
    const b = this.sourceBuffer && this.sourceBuffer.buffered;
    if (!b) return this._loadStart;
    let reached = this._loadStart;
    for (let i = 0; i < b.length; i++) {
      if (b.start(i) <= this._loadStart + 1 && b.end(i) > reached) reached = b.end(i);
    }
    return reached;
  }

  // The current stream's body has been read and appended in full. At the end
  // of the film that means end-of-stream, which is what lets the element fire
  // `ended`. Anywhere earlier the connection was cut short, so reading picks
  // up again from where the data stops.
  _finishStream() {
    this._streamEnded = false;
    const reached = this._reachedEnd();
    const nearEnd = !this.duration || reached >= this.duration - 2;
    if (reached > this._lastReached + 1) this._reopenAttempts = 0;
    this._lastReached = reached;

    if (nearEnd || this._reopenAttempts >= 5) {
      const ms = this.mediaSource;
      if (ms && ms.readyState === 'open' && !this.sourceBuffer.updating) {
        try { ms.endOfStream(); } catch {}
      }
      return;
    }
    this._reopenAttempts++;
    const at = Math.max(this._loadStart, reached - 0.5);
    console.log(`[mse] stream ended early at ${reached.toFixed(1)}s — continuing from there`);
    const gen = this._generation;
    clearTimeout(this._retryTimer);
    this._retryTimer = setTimeout(() => {
      if (!this._destroyed && gen === this._generation) this._open(at);
    }, 400 * this._reopenAttempts);
  }

  // endOfStream() shortens the declared duration to what's buffered; a later
  // seek back into the film needs the real running time restored.
  _restoreDuration() {
    const ms = this.mediaSource;
    if (!ms || !this.duration || ms.readyState !== 'open') return;
    if (this.sourceBuffer && this.sourceBuffer.updating) return;
    try { if (ms.duration < this.duration) ms.duration = this.duration; } catch {}
  }

  // Frees buffer space: first what is well behind the playhead, then whole
  // ranges away from it. Returns whether anything was removed.
  _evict() {
    const sb = this.sourceBuffer;
    if (!sb || sb.updating || !sb.buffered.length) return false;
    const cur = this.video.currentTime;
    const b = sb.buffered;
    const behind = Math.max(0, cur - 20);
    if (behind > b.start(0) + 1) {
      try { sb.remove(b.start(0), behind); return true; } catch { return false; }
    }
    let farthest = -1;
    let farthestDist = 0;
    for (let i = 0; i < b.length; i++) {
      if (cur >= b.start(i) - 1 && cur <= b.end(i) + 1) continue; // the range being played
      if (b.start(i) <= this._loadStart + 1 && b.end(i) >= this._loadStart) continue; // being filled
      const dist = Math.min(Math.abs(b.start(i) - cur), Math.abs(b.end(i) - cur));
      if (dist > farthestDist) { farthestDist = dist; farthest = i; }
    }
    if (farthest >= 0) {
      try { sb.remove(b.start(farthest), b.end(farthest)); return true; } catch { return false; }
    }
    return false;
  }
}

function concatChunks(chunks) {
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

// Some codec spellings are accepted by one Chromium build and not another
// (MP3 in MP4 especially), so the alternatives are tried in turn.
function pickSupportedMime(codecs) {
  const variants = [codecs];
  if (/mp4a\.6B|mp4a\.69/i.test(codecs)) variants.push(codecs.replace(/mp4a\.(6B|69)/i, 'mp3'));
  for (const c of variants) {
    const mime = `video/mp4; codecs="${c}"`;
    if (window.MediaSource.isTypeSupported(mime)) return mime;
  }
  return null;
}

// MediaSource insists on exact codec strings, and a wrong one makes
// addSourceBuffer throw (or the audio silently never decode). The real values
// sit in the init segment's sample descriptions, so they are read from there.
// Returns null until the whole `moov` box has arrived.
function parseCodecs(buf) {
  const moov = boxesIn(buf, 0, buf.length).find((b) => b.type === 'moov');
  if (!moov || moov.truncated) return null;

  const found = [];
  for (const trak of boxesIn(buf, moov.start, moov.end).filter((b) => b.type === 'trak')) {
    const stsd = descend(buf, trak, ['mdia', 'minf', 'stbl', 'stsd']);
    if (!stsd) continue;
    // stsd: version/flags (4) + entry count (4), then sample entries.
    const entryOff = stsd.start + 8;
    if (entryOff + 8 > stsd.end) continue;
    const entrySize = readU32(buf, entryOff);
    const type = fourcc(buf, entryOff + 4);
    const entryEnd = Math.min(stsd.end, entryOff + entrySize);
    const codec = sampleEntryCodec(buf, type, entryOff + 8, entryEnd);
    if (codec) found.push(codec);
  }

  if (!found.some((c) => /^(avc|hev|hvc)/.test(c))) {
    // Couldn't walk the structure; the old tag scan still finds H.264.
    const avcC = findTag(buf, moov.start, moov.end, 'avcC');
    if (avcC < 0) return null;
    const p = avcC + 4;
    return `avc1.${hex(buf[p + 1])}${hex(buf[p + 2])}${hex(buf[p + 3])}, mp4a.40.2`;
  }
  // Video first, then audio, is the order the tracks are written in.
  return found.join(', ');
}

function sampleEntryCodec(buf, type, payload, end) {
  if (type === 'avc1' || type === 'avc3') {
    const cfg = childBox(buf, payload + 78, end, 'avcC');
    if (!cfg) return null;
    const p = cfg.start;
    return `${type}.${hex(buf[p + 1])}${hex(buf[p + 2])}${hex(buf[p + 3])}`;
  }
  if (type === 'hev1' || type === 'hvc1') {
    const cfg = childBox(buf, payload + 78, end, 'hvcC');
    if (!cfg || cfg.end - cfg.start < 13) return null;
    const p = cfg.start;
    const space = ['', 'A', 'B', 'C'][buf[p + 1] >> 6];
    const tier = (buf[p + 1] >> 5) & 1 ? 'H' : 'L';
    const profile = buf[p + 1] & 0x1f;
    let compat = readU32(buf, p + 2);
    let reversed = 0;
    for (let i = 0; i < 32; i++) { reversed = (reversed << 1) | (compat & 1); compat >>>= 1; }
    const constraints = [];
    for (let i = 6; i < 12; i++) constraints.push(buf[p + i]);
    while (constraints.length && constraints[constraints.length - 1] === 0) constraints.pop();
    const level = buf[p + 12];
    return `${type}.${space}${profile}.${(reversed >>> 0).toString(16)}.${tier}${level}`
      + constraints.map((c) => `.${c.toString(16)}`).join('');
  }
  if (type === 'mp4a') {
    const esds = childBox(buf, payload + 28, end, 'esds');
    return esds ? esdsCodec(buf, esds.start + 4, esds.end) : 'mp4a.40.2';
  }
  if (type === 'Opus') return 'opus';
  if (type === 'fLaC') return 'flac';
  if (type === 'ac-3') return 'ac-3';
  if (type === 'ec-3') return 'ec-3';
  return null;
}

// Walks the MPEG-4 descriptors inside esds to the decoder config: its object
// type says AAC vs MP3, and for AAC the first bits of the decoder-specific
// info give the exact profile (LC, HE-AAC, ...).
function esdsCodec(buf, off, end) {
  const readDescriptor = (at) => {
    if (at + 2 > end) return null;
    const tag = buf[at];
    let len = 0;
    let i = at + 1;
    for (let n = 0; n < 4 && i < end; n++) {
      const b = buf[i++];
      len = (len << 7) | (b & 0x7f);
      if (!(b & 0x80)) break;
    }
    return { tag, start: i, end: Math.min(end, i + len) };
  };
  const es = readDescriptor(off);
  if (!es || es.tag !== 0x03) return 'mp4a.40.2';
  let at = es.start + 3; // ES_ID (2) + flags (1)
  const dc = readDescriptor(at);
  if (!dc || dc.tag !== 0x04) return 'mp4a.40.2';
  const oti = buf[dc.start];
  if (oti !== 0x40 && oti !== 0x66 && oti !== 0x67 && oti !== 0x68) {
    return `mp4a.${oti.toString(16).toUpperCase()}`;
  }
  at = dc.start + 13; // object type, stream type, buffer size, max/avg bitrate
  const dsi = readDescriptor(at);
  if (!dsi || dsi.tag !== 0x05 || dsi.start >= dsi.end) return 'mp4a.40.2';
  let aot = buf[dsi.start] >> 3;
  if (aot === 31 && dsi.start + 1 < dsi.end) aot = 32 + (((buf[dsi.start] & 0x07) << 3) | (buf[dsi.start + 1] >> 5));
  return `mp4a.40.${aot || 2}`;
}

// Lists the boxes laid end to end in [start, end). A box running past the
// data received so far is flagged as truncated.
function boxesIn(buf, start, end) {
  const out = [];
  let off = start;
  while (off + 8 <= end) {
    let size = readU32(buf, off);
    const type = fourcc(buf, off + 4);
    let header = 8;
    if (size === 1) {
      if (off + 16 > end) break;
      size = readU32(buf, off + 8) * 4294967296 + readU32(buf, off + 12);
      header = 16;
    } else if (size === 0) {
      size = end - off;
    }
    if (size < header) break;
    const boxEnd = off + size;
    out.push({ type, start: off + header, end: Math.min(boxEnd, end), truncated: boxEnd > end });
    off = boxEnd;
  }
  return out;
}

function childBox(buf, start, end, type) {
  if (start >= end) return null;
  return boxesIn(buf, start, end).find((b) => b.type === type) || null;
}

function descend(buf, box, path) {
  let cur = box;
  for (const name of path) {
    cur = childBox(buf, cur.start, cur.end, name);
    if (!cur) return null;
  }
  return cur;
}

function findTag(buf, start, end, tag) {
  const t0 = tag.charCodeAt(0), t1 = tag.charCodeAt(1), t2 = tag.charCodeAt(2), t3 = tag.charCodeAt(3);
  for (let i = start; i + 8 <= end && i + 8 <= buf.length; i++) {
    if (buf[i] === t0 && buf[i + 1] === t1 && buf[i + 2] === t2 && buf[i + 3] === t3) return i;
  }
  return -1;
}

function fourcc(buf, off) {
  return String.fromCharCode(buf[off], buf[off + 1], buf[off + 2], buf[off + 3]);
}

function hex(n) { return n.toString(16).padStart(2, '0'); }

function readU32(buf, off) {
  return ((buf[off] << 24) >>> 0) + (buf[off + 1] << 16) + (buf[off + 2] << 8) + buf[off + 3];
}

window.MseVodStreamer = MseVodStreamer;
