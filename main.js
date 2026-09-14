const { app, BrowserWindow, ipcMain, session } = require('electron');
const path = require('path');
const fs = require('fs');
const https = require('https');
const http = require('http');
const zlib = require('zlib');
const { spawn } = require('child_process');

const userDataDir = app.getPath('userData');
const storeFile = path.join(userDataDir, 'store.json');

function readStore() {
  try {
    return JSON.parse(fs.readFileSync(storeFile, 'utf-8'));
  } catch {
    return { accounts: [], activeAccountId: null, settings: {} };
  }
}

function writeStore(data) {
  fs.writeFileSync(storeFile, JSON.stringify(data, null, 2), 'utf-8');
}

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1400,
    height: 860,
    minWidth: 1000,
    minHeight: 650,
    backgroundColor: '#12101c',
    autoHideMenuBar: true,
    icon: path.join(__dirname, 'assets', 'icon.ico'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      // The UI loads from file:// while video segments/manifests come from
      // the user's own IPTV server. Browser CORS enforcement between those
      // origins was causing hls.js/mpegts.js segment fetches to fail and
      // retry repeatedly (several seconds of hidden retries) before our
      // fallback chain ever kicked in — the real cause of the slow starts.
      // This app never displays third-party web content, so disabling it
      // is safe and removes that entire class of delay.
      webSecurity: false,
      allowRunningInsecureContent: true
    }
  });

  mainWindow.setMenuBarVisibility(false);
  mainWindow.loadFile(path.join(__dirname, 'src', 'index.html'));

  // Mirror the renderer's console into this process's own stdout (which our
  // launch script redirects to run-out.log) so playback issues can be
  // diagnosed from the log file directly instead of guessing blind.
  mainWindow.webContents.on('console-message', (event, level, message, line, sourceId) => {
    console.log(`[renderer] ${message}`);
  });

  // mainWindow.webContents.openDevTools();
}

app.whenReady().then(async () => {
  await startProxyServer();
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

// ---- IPC: persistent store ----
ipcMain.handle('store:get', () => readStore());
ipcMain.handle('store:set', (_e, data) => {
  writeStore(data);
  return true;
});

// ---- IPC: simple HTTP(S) GET JSON proxy (avoids CORS issues, follows redirects) ----
function fetchText(url, redirects = 5, timeoutMs = 45000) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https') ? https : http;
    const req = lib.get(url, {
      timeout: timeoutMs,
      headers: { 'User-Agent': 'IPTVPlayer/1.0', 'Accept-Encoding': 'gzip, deflate, br' }
    }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects > 0) {
        const next = new URL(res.headers.location, url).toString();
        res.resume();
        fetchText(next, redirects - 1, timeoutMs).then(resolve).catch(reject);
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        res.resume();
        reject(new Error(`Server returned HTTP ${res.statusCode}`));
        return;
      }

      let stream = res;
      const enc = (res.headers['content-encoding'] || '').toLowerCase();
      try {
        if (enc === 'gzip') stream = res.pipe(zlib.createGunzip());
        else if (enc === 'deflate') stream = res.pipe(zlib.createInflate());
        else if (enc === 'br') stream = res.pipe(zlib.createBrotliDecompress());
      } catch (e) {
        reject(e);
        return;
      }

      let chunks = [];
      let total = 0;
      const MAX_BYTES = 80 * 1024 * 1024; // 80MB safety cap
      stream.on('data', (c) => {
        total += c.length;
        if (total > MAX_BYTES) {
          req.destroy(new Error('Response too large'));
          return;
        }
        chunks.push(c);
      });
      stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf-8')));
      stream.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('Connection timed out — server is not responding')));
    req.on('error', (err) => reject(new Error(err.message || 'Network error')));
  });
}

ipcMain.handle('net:getJson', async (_e, url) => {
  try {
    const text = await fetchText(url);
    try {
      return { ok: true, data: JSON.parse(text) };
    } catch (err) {
      return { ok: false, error: 'Server sent an invalid response', raw: text.slice(0, 500) };
    }
  } catch (err) {
    return { ok: false, error: err.message || 'Network error' };
  }
});

ipcMain.handle('net:getText', async (_e, url) => {
  try {
    const text = await fetchText(url);
    return { ok: true, data: text };
  } catch (err) {
    return { ok: false, error: err.message || 'Network error' };
  }
});

// ==============================================================
// Local ffmpeg remux/transcode proxy.
// Many IPTV VOD/live streams use containers or codecs (MKV, HEVC,
// unusual audio tracks, raw MPEG-TS) that Chromium's <video> element
// cannot play directly. Rather than fail, we transparently pipe the
// stream through ffmpeg (already on this machine) and re-package it
// as fragmented MP4 that <video> always understands.
//   mode=copy      -> just remux containers/streams, no re-encode (fast, near-zero CPU, no quality loss)
//   mode=transcode -> re-encode video/audio to H.264/AAC (fallback when the codec itself is unsupported)
// ==============================================================
let ffmpegPath = 'ffmpeg';
try {
  // If ffmpeg-static or a bundled binary exists, prefer it; otherwise fall back to PATH.
  const bundled = path.join(process.resourcesPath || '', 'ffmpeg', process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg');
  if (fs.existsSync(bundled)) ffmpegPath = bundled;
} catch { /* use PATH */ }

let proxyPort = 0;
const activeProxies = new Map(); // res -> ffmpeg child process, for cleanup (live streams only)

// ---- VOD cache: lets movies/episodes buffer ahead like YouTube ----
// A raw ffmpeg pipe behaves like a live stream to Chromium (chunked,
// no Content-Length/Range support), so the browser refuses to read far
// ahead of playback — that's what made the buffered-progress bar never
// extend past the playhead. For VOD we instead remux/transcode ONCE into a
// growing temp file and serve THAT with proper Range support, so the
// browser can freely buffer ahead exactly like a normal progressive video.
// The temp file is a private cache (deleted when the app closes), never a
// user-visible "download".
const crypto = require('crypto');
const os = require('os');
const cacheDir = path.join(os.tmpdir(), 'iptvplayer-cache');
try { fs.mkdirSync(cacheDir, { recursive: true }); } catch {}

const vodCache = new Map(); // key -> { filePath, bytesWritten, done, failed, ff, readers }

function cacheKeyFor(url, mode) {
  return crypto.createHash('sha1').update(`${mode}:${url}`).digest('hex');
}

function startVodCacheEntry(url, mode) {
  const key = cacheKeyFor(url, mode);
  const filePath = path.join(cacheDir, `${key}.mp4`);
  const entry = {
    key, filePath, bytesWritten: 0, done: false, failed: false,
    stderrTail: '', readers: 0, ff: null, idleKillTimer: null,
    failListeners: [], _downloadAbort: null, _contentLength: 0
  };
  vodCache.set(key, entry);

  const outputArgs = [
    ...(mode === 'transcode'
      ? ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-c:a', 'aac', '-b:a', '160k']
      : mode === 'audiofix'
        ? ['-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k']
        : ['-c', 'copy']),
    '-avoid_negative_ts', 'make_zero',
    '-f', 'mp4',
    '-movflags', 'frag_keyframe+empty_moov+delay_moov+default_base_moof',
    'pipe:1'
  ];

  let ff;
  try {
    const inputArgs = [
      '-loglevel', 'error', '-nostdin',
      '-i', 'pipe:0',
      '-map', '0:v:0?', '-map', '0:a:0?',
      ...outputArgs
    ];
    ff = spawn(ffmpegPath, inputArgs, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  } catch (err) {
    entry.failed = true;
    entry.stderrTail = 'ffmpeg spawn error: ' + err.message;
    entry.done = true;
    entry.failListeners.forEach((fn) => { try { fn(); } catch {} });
    entry.failListeners = [];
    return entry;
  }
  entry.ff = ff;

  const writeStream = fs.createWriteStream(filePath);
  ff.stdout.on('data', (chunk) => {
    const ok = writeStream.write(chunk, () => {
      entry.bytesWritten += chunk.length;
    });
    if (!ok) ff.stdout.pause();
  });
  writeStream.on('drain', () => ff.stdout.resume());
  ff.stderr.on('data', (d) => {
    const msg = d.toString().trim();
    if (msg) {
      entry.stderrTail = (entry.stderrTail + '\n' + msg).slice(-2000);
      console.error(`[ffmpeg/${mode}] ${msg}`);
    }
  });
  ff.on('close', (code) => {
    entry.done = true;
    writeStream.end();
    if (entry.bytesWritten === 0) {
      entry.failed = true;
      console.error(`[ffmpeg/${mode}] FAILED exit=${code} stderr=${entry.stderrTail.slice(0, 300)}`);
    } else {
      console.log(`[ffmpeg/${mode}] done, ${entry.bytesWritten} bytes written`);
    }
    if (entry.failListeners.length) {
      entry.failListeners.forEach((fn) => { try { fn(); } catch {} });
      entry.failListeners = [];
    }
  });
  ff.on('error', (err) => {
    entry.done = true;
    entry.failed = true;
    entry.stderrTail = 'ffmpeg error: ' + err.message;
    console.error(`[ffmpeg/${mode}] ERROR: ${err.message}`);
    if (entry.failListeners.length) {
      entry.failListeners.forEach((fn) => { try { fn(); } catch {} });
      entry.failListeners = [];
    }
  });

  ff.stdin.on('error', () => {});

  downloadWithReconnect(url, ff.stdin, entry);

  return entry;
}

function downloadWithReconnect(originalUrl, dest, entry) {
  let totalDownloaded = 0;
  let closed = false;

  function tryClose() {
    if (!closed) {
      closed = true;
      try { if (dest && !dest.destroyed) dest.end(); } catch {}
    }
  }

  function failEntry(msg) {
    if (entry.done) return;
    entry.stderrTail = msg;
    entry.failed = true;
    entry.done = true;
    tryClose();
    if (entry.failListeners.length) {
      entry.failListeners.forEach((fn) => { try { fn(); } catch {} });
      entry.failListeners = [];
    }
  }

  function scheduleReconnect(delayMs) {
    if (closed || entry.done || (dest && dest.destroyed)) return;
    console.log(`[download] reconnecting in ${delayMs}ms to original URL (have ${totalDownloaded} bytes)...`);
    setTimeout(() => fetchChunk(originalUrl, 0), delayMs);
  }

  function fetchChunk(url, depth) {
    if (closed || entry.done) return;
    if (depth > 5) {
      console.error(`[download] too many redirects`);
      failEntry('Too many redirects');
      return;
    }

    const parsedUrl = new URL(url);
    const proto = parsedUrl.protocol === 'https:' ? require('https') : require('http');
    const headers = {
      'User-Agent': 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100',
      'Referer': `${parsedUrl.protocol}//${parsedUrl.host}/`
    };
    if (totalDownloaded > 0) {
      headers['Range'] = `bytes=${totalDownloaded}-`;
    }

    const opts = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
      path: parsedUrl.pathname + parsedUrl.search,
      method: 'GET',
      headers,
      timeout: 15000
    };

    console.log(`[download] GET ${parsedUrl.hostname}${parsedUrl.pathname}` + (totalDownloaded > 0 ? ` Range:bytes=${totalDownloaded}-` : ''));

    const req = proto.get(opts, (res) => {
      if (closed || entry.done) { res.resume(); return; }

      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        console.log(`[download] ${res.statusCode} redirect`);
        res.resume();
        const redirectUrl = new URL(res.headers.location, url);
        fetchChunk(redirectUrl.href, depth + 1);
        return;
      }

      if (res.statusCode !== 200 && res.statusCode !== 206) {
        console.error(`[download] HTTP ${res.statusCode}`);
        res.resume();
        if (res.statusCode === 509 || res.statusCode === 429) {
          scheduleReconnect(1000);
        } else {
          failEntry(`HTTP ${res.statusCode}`);
        }
        return;
      }

      if (res.statusCode === 206) {
        console.log(`[download] HTTP 206 resumed from ${totalDownloaded}`);
      } else {
        console.log(`[download] HTTP 200 content-length=${res.headers['content-length']}`);
        const cl = parseInt(res.headers['content-length']);
        if (cl > 0) entry._contentLength = cl;
      }

      res.on('data', (chunk) => {
        if (closed || entry.done || (dest && dest.destroyed)) return;
        totalDownloaded += chunk.length;
        try { dest.write(chunk); } catch {}
      });

      res.on('end', () => {
        console.log(`[download] ended at ${totalDownloaded} bytes`);
      });

      res.on('error', (err) => {
        console.error(`[download] response error: ${err.message}`);
        if (!closed && !entry.done && !(dest && dest.destroyed) && totalDownloaded > 0) {
          scheduleReconnect(500);
        } else {
          tryClose();
        }
      });
    });

    req.on('error', (err) => {
      console.error(`[download] request error: ${err.message}`);
      if (!closed && !entry.done && !(dest && dest.destroyed) && totalDownloaded > 0) {
        scheduleReconnect(500);
      } else if (!closed) {
        failEntry('Connection failed: ' + err.message);
      }
    });

    req.on('timeout', () => {
      console.error(`[download] timeout`);
      req.destroy();
    });

    entry._downloadAbort = () => {
      closed = true;
      req.destroy();
      tryClose();
    };
  }

  fetchChunk(originalUrl, 0);
}



function getOrCreateVodEntry(url, mode) {
  const key = cacheKeyFor(url, mode);
  const existing = vodCache.get(key);
  // Reuse a cache entry unless its ffmpeg process died with nothing to show.
  if (existing && !(existing.done && existing.failed)) {
    console.log(`[vod-cache] reusing existing entry mode=${mode} key=${key.slice(0, 8)} bytes=${existing.bytesWritten}`);
    return existing;
  }
  if (existing && existing.done && existing.failed) {
    console.log(`[vod-cache] previous entry FAILED, starting new one mode=${mode} stderr=${existing.stderrTail.slice(0, 200)}`);
  }
  return startVodCacheEntry(url, mode);
}

// Called once per HTTP request as soon as it attaches to an entry (whether
// it's still waiting for the first bytes or already streaming) and exactly
// once more when that request ends. When an entry has zero attached
// requests for a few seconds — e.g. the copy-mode attempt got abandoned in
// favor of transcode, or the user backed out of the player — its ffmpeg
// process is killed and the cache file removed. Without this, abandoned
// attempts kept running (and competing for the same source connection)
// forever in the background, which is what made *every* stream eventually
// grind to a halt.
function addVodReader(entry) {
  entry.readers++;
  if (entry.idleKillTimer) { clearTimeout(entry.idleKillTimer); entry.idleKillTimer = null; }
}
function releaseVodReader(entry) {
  entry.readers = Math.max(0, entry.readers - 1);
  if (entry.readers === 0) {
    entry.idleKillTimer = setTimeout(() => {
      if (entry.readers > 0) return;
      try { if (entry._downloadAbort) entry._downloadAbort(); } catch {}
      try { if (entry.ff) entry.ff.kill('SIGKILL'); } catch {}
      try { fs.unlinkSync(entry.filePath); } catch {}
      if (vodCache.get(entry.key) === entry) vodCache.delete(entry.key);
    }, 5000);
  }
}

// Serves data from an already-downloaded cache file by spawning a local ffmpeg
// with -ss to seek instantly within what has been downloaded so far. This avoids
// re-downloading from the network on every seek. If the cache file doesn't yet
// have enough data for the requested seek position, it falls back to the normal
// grow-from-byte-0 approach. When ffmpeg reaches the current end of the file
// while the download is still running, it restarts automatically.
function serveFromCacheFile(entry, seekSec, res, onDone) {
  let closed = false;
  const cleanup = () => { if (!closed) { closed = true; onDone(); } };
  res.on('close', cleanup);

  function startLocalFfmpeg() {
    if (closed) return;
    const args = [
      '-loglevel', 'error',
      '-ss', String(seekSec),
      '-i', entry.filePath,
      '-c', 'copy',
      '-f', 'mp4',
      '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
      'pipe:1'
    ];
    let ff;
    try {
      ff = spawn(ffmpegPath, args, { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch {
      if (!closed && !res.writableEnded) res.end();
      cleanup();
      return;
    }
    ff.stdout.pipe(res, { end: false });
    ff.stderr.on('data', () => {});
    ff.on('close', () => {
      if (closed) return;
      if (entry.done || entry.failed) {
        if (!res.writableEnded) res.end();
        cleanup();
      } else {
        // Download is still running — wait a bit for more data, then retry.
        // The restarted ffmpeg will re-read the (now larger) file from disk.
        setTimeout(startLocalFfmpeg, 300);
      }
    });
  }
  startLocalFfmpeg();
}

// Streams bytes [start, ) from a still-growing cache file, waiting for more
// data to be written if we catch up to the current end but ffmpeg isn't
// done yet — this is what lets playback start immediately while the rest
// keeps buffering in behind it, same as YouTube.
function serveGrowingFile(entry, start, res, onDone) {
  let position = start;
  let closed = false;
  const CHUNK = 256 * 1024;
  let fd;
  try {
    fd = fs.openSync(entry.filePath, 'r');
  } catch {
    res.writeHead(500).end('Cache file not available');
    if (onDone) onDone();
    return;
  }

  const cleanup = () => {
    if (closed) return;
    closed = true;
    try { fs.closeSync(fd); } catch {}
    if (onDone) onDone();
  };
  res.on('close', cleanup);

  function pump() {
    if (closed) return;
    if (entry.failed && position >= entry.bytesWritten) {
      cleanup();
      if (!res.writableEnded) res.end();
      return;
    }
    if (position >= entry.bytesWritten) {
      if (entry.done) { cleanup(); res.end(); return; }
      setTimeout(pump, 100);
      return;
    }
    const toRead = Math.min(CHUNK, entry.bytesWritten - position);
    const buf = Buffer.alloc(toRead);
    fs.read(fd, buf, 0, toRead, position, (err, bytesRead) => {
      if (closed) return;
      if (err || bytesRead <= 0) { cleanup(); res.end(); return; }
      position += bytesRead;
      const ok = res.write(buf.subarray(0, bytesRead));
      if (ok) pump();
      else res.once('drain', pump);
    });
  }
  pump();
}

// Best-effort cleanup of the on-disk cache: on app quit, and any entry
// finished-and-unread for a while (guards against a very long session).
function clearVodCache() {
  for (const entry of vodCache.values()) {
    try { if (entry.ff) entry.ff.kill('SIGKILL'); } catch {}
    try { fs.unlinkSync(entry.filePath); } catch {}
  }
  vodCache.clear();
}
app.on('before-quit', clearVodCache);
try {
  // Wipe any leftovers from a previous crashed/killed session.
  for (const f of fs.readdirSync(cacheDir)) {
    try { fs.unlinkSync(path.join(cacheDir, f)); } catch {}
  }
} catch {}

function startProxyServer() {
  const server = http.createServer((req, res) => {
    let parsed;
    try {
      parsed = new URL(req.url, 'http://127.0.0.1');
    } catch {
      res.writeHead(400).end('Bad request');
      return;
    }

    if (parsed.pathname === '/debugtest') {
      const target = parsed.searchParams.get('url') || '';
      const mode = parsed.searchParams.get('mode') || 'copy';
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(`<!DOCTYPE html><html><body style="background:#000">
        <video id="v" controls style="width:100%" src="/stream?url=${encodeURIComponent(target)}&mode=${mode}&live=0&seek=0&t=dbg${Date.now()}"></video>
        <pre id="log" style="color:#0f0;font-family:monospace"></pre>
        <script>
          const v = document.getElementById('v');
          const log = (m) => { document.getElementById('log').textContent += m + '\\n'; };
          ['loadstart','loadedmetadata','loadeddata','canplay','playing','error','stalled','waiting'].forEach(ev => {
            v.addEventListener(ev, () => log('EVENT: ' + ev + (v.error ? ' ERROR code=' + v.error.code + ' msg=' + v.error.message : '')));
          });
        </script>
      </body></html>`);
      return;
    }

    if (parsed.pathname === '/probe') {
      const target = parsed.searchParams.get('url');
      if (!target) { res.writeHead(400).end('Missing url'); return; }
      // The proxied stream is a fragmented MP4 with no known total length
      // (ffmpeg is remuxing on the fly), so the browser's own <video>
      // duration keeps re-estimating itself as more data arrives — that's
      // what made the seek bar drift/jump. ffprobe reads the real duration
      // from the source directly so the UI can show a stable, correct one.
      // Also report the audio/video codecs: AC3/EAC3/DTS/TrueHD audio (very
      // common in IPTV .mkv releases) has NO decoder in Chromium at all, so
      // a plain "-c copy" remux produces a file that LOOKS valid but never
      // actually plays (no error, no sound, sometimes no video either).
      // Knowing this upfront lets us skip straight to fixing just the audio
      // instead of wasting a doomed copy attempt every single time.
      const probeArgs = [
        '-v', 'error',
        '-user_agent', 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100',
        '-show_entries', 'format=duration:stream=codec_type,codec_name',
        '-of', 'json',
        target
      ];
      const ffprobePath = ffmpegPath.replace(/ffmpeg(\.exe)?$/i, (m, ext) => `ffprobe${ext || ''}`);
      const fp = spawn(ffprobePath, probeArgs, { windowsHide: true });
      let out = '';
      fp.stdout.on('data', (d) => { out += d; });
      fp.on('close', () => {
        try {
          const parsed2 = JSON.parse(out);
          const duration = parseFloat(parsed2.format && parsed2.format.duration);
          const streams = parsed2.streams || [];
          const videoCodec = (streams.find((s) => s.codec_type === 'video') || {}).codec_name || null;
          const audioCodec = (streams.find((s) => s.codec_type === 'audio') || {}).codec_name || null;
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ duration: isFinite(duration) ? duration : null, videoCodec, audioCodec }));
        } catch {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ duration: null, videoCodec: null, audioCodec: null }));
        }
      });
      fp.on('error', () => {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ duration: null, videoCodec: null, audioCodec: null }));
      });
      return;
    }

    if (parsed.pathname !== '/stream') {
      res.writeHead(404).end('Not found');
      return;
    }

    const target = parsed.searchParams.get('url');
    const modeParam = parsed.searchParams.get('mode');
    const mode = ['transcode', 'audiofix'].includes(modeParam) ? modeParam : 'copy';
    const isLive = parsed.searchParams.get('live') === '1';
    const seekSec = Math.max(0, parseFloat(parsed.searchParams.get('seek') || '0') || 0);
    if (!target) {
      res.writeHead(400).end('Missing url');
      return;
    }

    if (!isLive) {
      // VOD: serve from (or start) the growing cache file so the browser
      // buffers ahead like a normal progressive video, instead of the raw
      // live-style pipe that made the buffered bar never move ahead of the
      // playhead.
      //
      // Deliberately NOT honoring Range/206 here: this is a fragmented mp4
      // with no fixed total length (ffmpeg is still writing it), and a
      // 206 response with an open-ended `Content-Range: bytes X-*/*` is not
      // something Chromium's media pipeline handles reliably — it was the
      // actual cause of every playback attempt eventually failing with
      // "MEDIA_ELEMENT_ERROR: Format error". We don't need Range support
      // for our own seeking anyway (seekTo() restarts ffmpeg at the target
      // timestamp instead), so every request just gets a plain 200 stream
      // starting from byte 0.
      const entry = getOrCreateVodEntry(target, mode);

      addVodReader(entry);
      let aborted = false;
      let released = false;
      let pollTimer = null;
      let served = false;
      const release = () => { if (!released) { released = true; releaseVodReader(entry); } };
      req.on('close', () => { aborted = true; if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } release(); });

      // If seeking within an already-downloaded cache file, serve from the
      // local file instantly — no need to re-download from the network.
      if (seekSec > 0 && entry.bytesWritten > 0 && !entry.done) {
        // Estimate bytes needed: typical 720p MKV is ~500KB-1MB/s.
        // Use 1MB/s as a generous estimate so we try local cache early.
        const estimatedBytesNeeded = seekSec * 1000000;
        const dataOnDisk = entry.bytesWritten >= estimatedBytesNeeded;
        console.log(`[stream] seek=${seekSec.toFixed(1)}s cache=${(entry.bytesWritten/1048576).toFixed(1)}MB needed~${(estimatedBytesNeeded/1048576).toFixed(1)}MB onDisk=${dataOnDisk}`);
        served = true;
        if (dataOnDisk) {
          console.log(`[stream] serving from local cache (instant seek)`);
          // No Content-Length here: local ffmpeg re-muxes from seekSec, output
          // is shorter than the original file and we don't know the exact size.
          res.writeHead(200, { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' });
          serveFromCacheFile(entry, seekSec, res, release);
        } else {
          // Not enough data cached yet — wait for the download to reach
          // the seek position, then serve via local ffmpeg with -ss.
          console.log(`[stream] waiting for cache to reach seek position...`);
          res.writeHead(200, { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' });
          let seekPoll = null;
          const seekPollFn = () => {
            if (aborted || res.writableEnded) { if (seekPoll) { clearInterval(seekPoll); seekPoll = null; } return; }
            if (entry.bytesWritten >= estimatedBytesNeeded || entry.done) {
              if (seekPoll) { clearInterval(seekPoll); seekPoll = null; }
              if (!aborted && !res.writableEnded) {
                serveFromCacheFile(entry, seekSec, res, release);
              }
            }
          };
          seekPoll = setInterval(seekPollFn, 200);
          req.on('close', () => { if (seekPoll) { clearInterval(seekPoll); seekPoll = null; } });
        }
        return;
      }

      const waitThenServe = () => {
        if (aborted || res.writableEnded || served) return;
        try {
          if (entry.failed && entry.bytesWritten === 0) {
            res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end('ffmpeg failed: ' + (entry.stderrTail || 'no output'));
            return;
          }
          if (entry.bytesWritten === 0 && !entry.done) {
            if (!pollTimer) {
              const onFail = () => { if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } waitThenServe(); };
              entry.failListeners.push(onFail);
              pollTimer = setInterval(() => {
                if (aborted || res.writableEnded || entry.bytesWritten > 0 || entry.done) {
                  clearInterval(pollTimer);
                  pollTimer = null;
                  if (!aborted && !res.writableEnded) waitThenServe();
                }
              }, 100);
            }
            return;
          }
          if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
          served = true;
          const initHeaders = { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' };
          if (entry._contentLength > 0) initHeaders['Content-Length'] = entry._contentLength;
          res.writeHead(200, initHeaders);
          serveGrowingFile(entry, 0, res, release);
        } catch { /* client already gone */ }
      };
      waitThenServe();
      return;
    }

    const commonArgs = [
      '-loglevel', 'error',
      '-nostdin',
      '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '4',
      '-user_agent', 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100',
      '-i', target,
      '-map', '0:v:0?',
      '-map', '0:a:0?'
    ];

    const outArgs = mode === 'transcode'
      ? ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-c:a', 'aac', '-b:a', '160k']
      : ['-c', 'copy'];

    const args = [
      ...commonArgs,
      ...outArgs,
      '-f', 'mp4',
      '-movflags', 'frag_keyframe+empty_moov+delay_moov+default_base_moof',
      'pipe:1'
    ];

    let ff;
    try {
      ff = spawn(ffmpegPath, args, { windowsHide: true });
    } catch (err) {
      res.writeHead(500).end('ffmpeg not available: ' + err.message);
      return;
    }

    activeProxies.set(res, ff);
    let headerWritten = false;
    let stderrTail = '';

    ff.stdout.once('data', () => {
      if (!headerWritten) {
        headerWritten = true;
        res.writeHead(200, { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' });
      }
    });
    ff.stdout.pipe(res);

    ff.stderr.on('data', (d) => {
      stderrTail = (stderrTail + d.toString()).slice(-2000);
    });

    ff.on('close', (code) => {
      activeProxies.delete(res);
      if (!headerWritten) {
        // ffmpeg produced no output at all — surface as an error instead of hanging.
        res.writeHead(502, { 'Content-Type': 'text/plain' });
        res.end('ffmpeg failed: ' + (stderrTail || `exit code ${code}`));
      } else if (!res.writableEnded) {
        res.end();
      }
    });

    ff.on('error', (err) => {
      activeProxies.delete(res);
      if (!headerWritten) {
        res.writeHead(500).end('ffmpeg spawn error: ' + err.message);
      }
    });

    req.on('close', () => {
      if (activeProxies.has(res)) {
        try { ff.kill('SIGKILL'); } catch {}
        activeProxies.delete(res);
      }
    });
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      proxyPort = server.address().port;
      resolve(server);
    });
  });
}

ipcMain.handle('proxy:getBase', () => {
  return proxyPort ? `http://127.0.0.1:${proxyPort}` : null;
});

ipcMain.handle('app:getVersion', () => app.getVersion());
