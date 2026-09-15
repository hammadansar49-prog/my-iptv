const { app, BrowserWindow, ipcMain, session, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const https = require('https');
const http = require('http');
const zlib = require('zlib');
const { spawn } = require('child_process');

// The app's name shows in the window, the installer and Windows itself.
// Saved playlists, history and settings stay in the folder earlier builds
// used, so renaming the app doesn't make anyone sign in again.
app.setName('MY IPTV');
app.setPath('userData', path.join(app.getPath('appData'), 'iptv-player'));
const userDataDir = app.getPath('userData');
const storeFile = path.join(userDataDir, 'store.json');
// The catalog snapshot (tens of thousands of channels, movies and series)
// lives in its own file. Keeping it inside store.json meant every routine
// save — watch progress ticks every few seconds, a settings toggle, closing
// a video — rewrote tens of megabytes and froze the app for a minute.
const catalogFile = path.join(userDataDir, 'catalog.json');

function readStore() {
  try {
    const data = JSON.parse(fs.readFileSync(storeFile, 'utf-8'));
    if (data && data.dataCache) {
      // Older builds kept the catalog in here and grew this file to tens of
      // megabytes; rewrite it slim right away so it is never read or sent
      // across to the window at that size again.
      delete data.dataCache;
      try { writeStore(data); } catch {}
    }
    return data;
  } catch {
    return { accounts: [], activeAccountId: null, settings: {} };
  }
}

function writeStore(data) {
  const slim = Object.assign({}, data);
  delete slim.dataCache;
  fs.writeFileSync(storeFile, JSON.stringify(slim, null, 2), 'utf-8');
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

  // Closing while the player was fullscreen left a black window hanging
  // until Esc was pressed. Fullscreen is left first, streams are let go, and
  // if the page still doesn't let the window close promptly (busy saving,
  // or stuck in a long task) it is closed anyway.
  let forceCloseTimer = null;
  mainWindow.on('close', () => {
    stopAllProviderWork();
    try { if (mainWindow.isFullScreen()) mainWindow.setFullScreen(false); } catch {}
    try { mainWindow.webContents.executeJavaScript('document.fullscreenElement && document.exitFullscreen()', true).catch(() => {}); } catch {}
    if (!forceCloseTimer) {
      forceCloseTimer = setTimeout(() => {
        if (mainWindow && !mainWindow.isDestroyed()) mainWindow.destroy();
      }, 1500);
    }
  });
  mainWindow.on('closed', () => {
    if (forceCloseTimer) { clearTimeout(forceCloseTimer); forceCloseTimer = null; }
    mainWindow = null;
  });

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
  revalidateLicenseInBackground();
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
// License key gate. Update LICENSE_SERVER_URL to the deployed
// license-server (see license-server/README.md) before shipping a build.
// ==============================================================
const LICENSE_SERVER_URL = process.env.MYIPTV_LICENSE_SERVER_URL || 'http://localhost:4100';

function getMachineId() {
  const raw = [os.hostname(), os.platform(), os.arch(), (os.cpus()[0] || {}).model || '', os.userInfo().username]
    .join('|');
  return crypto.createHash('sha256').update(raw).digest('hex');
}

function postJson(url, body, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const lib = u.protocol === 'https:' ? https : http;
    const payload = JSON.stringify(body);
    const req = lib.request(u, {
      method: 'POST',
      timeout: timeoutMs,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
    }, (res) => {
      let chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try {
          const text = Buffer.concat(chunks).toString('utf-8');
          resolve({ status: res.statusCode, data: text ? JSON.parse(text) : {} });
        } catch (e) {
          reject(new Error('Server sent an invalid response'));
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('Connection timed out — server is not responding')));
    req.on('error', (err) => reject(new Error(err.message || 'Network error')));
    req.write(payload);
    req.end();
  });
}

function readLicense() {
  const store = readStore();
  return (store && store.license) || null;
}

function writeLicense(license) {
  const store = readStore();
  store.license = license;
  writeStore(store);
}

function localLicenseStatus() {
  const lic = readLicense();
  if (!lic || !lic.expiresAt) return { valid: false };
  return { valid: lic.expiresAt > Date.now(), plan: lic.plan, expiresAt: lic.expiresAt };
}

ipcMain.handle('license:getStatus', () => localLicenseStatus());

ipcMain.handle('license:getPlans', async () => {
  try {
    const text = await fetchText(`${LICENSE_SERVER_URL}/plans`);
    const data = JSON.parse(text);
    return { ok: true, plans: data.plans || [] };
  } catch (err) {
    return { ok: false, error: err.message || 'Network error', plans: [] };
  }
});

ipcMain.handle('license:getSettings', async () => {
  try {
    const text = await fetchText(`${LICENSE_SERVER_URL}/settings`);
    const data = JSON.parse(text);
    return { ok: true, settings: data.settings || {} };
  } catch (err) {
    return { ok: false, error: err.message || 'Network error', settings: {} };
  }
});

ipcMain.handle('shell:openExternal', (_e, url) => {
  // Only ever used for the WhatsApp deep link built from admin-configured
  // data, but keep it locked to wa.me/https URLs regardless of caller.
  if (typeof url === 'string' && /^https:\/\/(wa\.me|api\.whatsapp\.com)\//.test(url)) {
    shell.openExternal(url);
    return true;
  }
  return false;
});

ipcMain.handle('license:verify', async (_e, key) => {
  try {
    const machineId = getMachineId();
    const { data } = await postJson(`${LICENSE_SERVER_URL}/verify`, { key: String(key || '').trim(), machineId });
    if (data.valid) {
      writeLicense({ key: String(key).trim(), plan: data.plan, expiresAt: data.expiresAt, lastVerifiedAt: Date.now() });
      return { valid: true, plan: data.plan, expiresAt: data.expiresAt };
    }
    return { valid: false, reason: data.reason || 'invalid' };
  } catch (err) {
    return { valid: false, reason: 'network-error', error: err.message || 'Network error' };
  }
});

// Background re-check of an already-saved license: catches revocations/
// early expiry without forcing every boot to wait on a network round trip.
// Never blocks — if offline, the last locally-cached expiry keeps working.
async function revalidateLicenseInBackground() {
  const lic = readLicense();
  if (!lic || !lic.key) return;
  const dayMs = 24 * 60 * 60 * 1000;
  if (lic.lastVerifiedAt && Date.now() - lic.lastVerifiedAt < dayMs) return;
  try {
    const machineId = getMachineId();
    const { data } = await postJson(`${LICENSE_SERVER_URL}/verify`, { key: lic.key, machineId });
    if (data.valid) {
      writeLicense({ ...lic, plan: data.plan, expiresAt: data.expiresAt, lastVerifiedAt: Date.now() });
    } else {
      writeLicense({ ...lic, expiresAt: 0 });
    }
  } catch {
    // Offline or server unreachable — keep the last known local state.
  }
}

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
let thumbPorts = [];
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

// Poster/logo thumbnails. Providers hand out full-size artwork (often
// 1000x1500 and a few hundred KB each), and a grid of those is slow to fill
// in even on a fast connection. These get downscaled once to grid size and
// kept — deliberately in their own directory, since the video cache next
// door is wiped on every launch and these are worth keeping between runs.
const thumbDir = path.join(os.tmpdir(), 'iptvplayer-thumbs');
try { fs.mkdirSync(thumbDir, { recursive: true }); } catch {}
try {
  const files = fs.readdirSync(thumbDir);
  if (files.length > 6000) {
    files
      .map((f) => {
        let t = 0;
        try { t = fs.statSync(path.join(thumbDir, f)).mtimeMs; } catch {}
        return { f, t };
      })
      .sort((a, b) => a.t - b.t)
      .slice(0, files.length - 4000)
      .forEach(({ f }) => { try { fs.unlinkSync(path.join(thumbDir, f)); } catch {} });
  }
} catch {}

// Thumbnails are built in the background, never while a request waits, so
// a slow or dead image host can only cost the *next* visit its speed-up.
// Downscaling spawns an ffmpeg per image, hence the cap.
const THUMB_CONCURRENCY = 4;
let thumbActive = 0;
const thumbQueue = [];
const thumbPending = new Set();
const thumbFailures = new Map(); // url -> when it last failed

function pumpThumbQueue() {
  while (thumbActive < THUMB_CONCURRENCY && thumbQueue.length) {
    const job = thumbQueue.shift();
    thumbActive++;
    job(() => { thumbActive--; pumpThumbQueue(); });
  }
}

// Content type from the bytes themselves where possible; extensions on
// these URLs are often wrong or missing.
function guessImageType(url, buf) {
  if (buf.length > 3 && buf[0] === 0xFF && buf[1] === 0xD8) return 'image/jpeg';
  if (buf.length > 8 && buf[0] === 0x89 && buf[1] === 0x50) return 'image/png';
  if (buf.length > 12 && buf.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  if (buf.length > 3 && buf.toString('ascii', 0, 3) === 'GIF') return 'image/gif';
  if (/\.svg(\?|$)/i.test(url)) return 'image/svg+xml';
  return 'application/octet-stream';
}

function queueThumbBuild(target, w, file, key, alreadyFetched) {
  if (thumbPending.has(key) || thumbQueue.length > 400) return;
  thumbPending.add(key);

  thumbQueue.push((done) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(watchdog);
      thumbPending.delete(key);
      done();
    };
    // A job that never calls back would hold its slot forever and stall
    // every thumbnail queued behind it.
    const watchdog = setTimeout(finish, 25000);

    const withBytes = (err, buf) => {
      if (settled) return;
      if (err || !buf || !buf.length) { finish(); return; }
      let ff;
      try {
        ff = spawn(ffmpegPath, [
          '-loglevel', 'error',
          '-i', 'pipe:0',
          '-vf', `scale='min(${w},iw)':-2`,
          '-q:v', '6',
          '-f', 'mjpeg',
          'pipe:1'
        ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
      } catch {
        finish();
        return;
      }
      const out = [];
      ff.stdout.on('data', (d) => out.push(d));
      ff.stderr.on('data', () => {});
      ff.on('error', finish);
      ff.on('close', () => {
        if (settled) return;
        const img = Buffer.concat(out);
        if (img.length) { try { fs.writeFileSync(file, img); } catch {} }
        finish();
      });
      ff.stdin.on('error', () => {});
      ff.stdin.end(buf);
    };

    // The request path usually has the bytes already; no need to pull them
    // down a second time just to make the small copy.
    if (alreadyFetched && alreadyFetched.length) withBytes(null, alreadyFetched);
    else fetchImage(sizedArtworkUrl(target, w), 0, withBytes);
  });
  pumpThumbQueue();
}

// Posters come from a handful of hosts, mostly image.tmdb.org. Opening a
// fresh TLS connection per poster cost more than the image itself on this
// network (a second or more each), so connections are kept and reused.
const imageAgents = {
  'http:': new http.Agent({ keepAlive: true, maxSockets: 12, maxFreeSockets: 12, scheduling: 'lifo' }),
  'https:': new https.Agent({ keepAlive: true, maxSockets: 12, maxFreeSockets: 12, scheduling: 'lifo' })
};

// TMDB serves every poster in several sizes, and providers link the 600px
// one — five times the bytes a grid card can show. The grid asks for the
// size closest to what it will display.
function sizedArtworkUrl(url, w) {
  const m = /^(https?:\/\/image\.tmdb\.org\/t\/p\/)[^/]+(\/.+)$/i.exec(url);
  if (!m) return url;
  const size = w <= 200 ? 'w185' : w <= 342 ? 'w342' : w <= 500 ? 'w500' : 'w780';
  return `${m[1]}${size}${m[2]}`;
}

// Calls back exactly once. The returned handle aborts the download, e.g.
// when the poster that asked for it has already scrolled away.
function fetchImage(url, depth, cb, handle) {
  const h = handle || { aborted: false, request: null, abort() { this.aborted = true; if (this.request) this.request.destroy(); } };
  let called = false;
  const done = (err, buf) => { if (!called) { called = true; cb(err, buf); } };
  if (h.aborted) { done(new Error('aborted')); return h; }
  if (depth > 4) { done(new Error('too many redirects')); return h; }
  let u;
  try { u = new URL(url); } catch { done(new Error('bad url')); return h; }
  const proto = u.protocol === 'https:' ? require('https') : require('http');
  const request = proto.get({
    hostname: u.hostname,
    port: u.port || (u.protocol === 'https:' ? 443 : 80),
    path: u.pathname + u.search,
    headers: { 'User-Agent': 'Mozilla/5.0' },
    agent: imageAgents[u.protocol],
    timeout: 10000
  }, (r) => {
    if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
      r.resume();
      let next;
      try { next = new URL(r.headers.location, url).href; } catch { done(new Error('bad redirect')); return; }
      fetchImage(next, depth + 1, done, h);
      return;
    }
    if (r.statusCode !== 200) { r.resume(); done(new Error('HTTP ' + r.statusCode)); return; }
    const chunks = [];
    let size = 0;
    r.on('data', (c) => {
      size += c.length;
      if (size > 12 * 1024 * 1024) { request.destroy(new Error('too large')); return; }
      chunks.push(c);
    });
    r.on('end', () => done(null, Buffer.concat(chunks)));
    r.on('error', (e) => done(e));
    r.on('aborted', () => done(new Error('aborted')));
  });
  h.request = request;
  request.on('error', (e) => done(e));
  request.on('timeout', () => request.destroy(new Error('timeout')));
  return h;
}


const vodCache = new Map(); // key -> { filePath, bytesWritten, done, failed, ff, readers }

// Each audio track gets its own cache: the remuxed file carries just one.
function cacheKeyFor(url, mode, audio = 0) {
  return crypto.createHash('sha1').update(`${mode}${audio ? `:a${audio}` : ''}:${url}`).digest('hex');
}

// ---- Subtitles ----
//
// Text subtitles are pulled out by the same ffmpeg that is already reading
// the film (the cache download, or a seek), as extra WebVTT outputs next to
// the video. A separate subtitle extraction would need a second connection
// to the provider — which a one-connection account refuses — and would have
// to read the whole file before showing anything. Cues are collected per
// film under their absolute position, and the window fetches them from
// /subs as they arrive.
// Only the common text formats: a conversion ffmpeg refuses would stop the
// whole process, video included.
const TEXT_SUBTITLE_CODECS = new Set(['subrip', 'srt', 'ass', 'ssa', 'mov_text', 'webvtt', 'text']);
const subtitleStore = new Map(); // url -> Map(subtitle index -> { cues: [[start, end, text]], keys: Set })

function textSubtitleTracks(url) {
  const probed = probeCache.get(url);
  return probed && Array.isArray(probed.subtitleTracks) ? probed.subtitleTracks.filter((t) => t.text) : [];
}

// ffmpeg arguments for one WebVTT output per text subtitle track.
function subtitleOutputs(url, prefix) {
  const args = [];
  const files = [];
  for (const t of textSubtitleTracks(url)) {
    const file = path.join(cacheDir, `${prefix}.s${t.index}.vtt`);
    args.push('-map', `0:s:${t.index}`, '-c:s', 'webvtt', '-flush_packets', '1', '-f', 'webvtt', '-y', file);
    files.push({ sub: t.index, file });
  }
  return { args, files };
}

function subtitleTrackStore(url, sub) {
  let byUrl = subtitleStore.get(url);
  if (!byUrl) {
    byUrl = new Map();
    subtitleStore.set(url, byUrl);
    if (subtitleStore.size > 4) subtitleStore.delete(subtitleStore.keys().next().value);
  }
  let track = byUrl.get(sub);
  if (!track) { track = { cues: [], keys: new Set() }; byUrl.set(sub, track); }
  return track;
}

function parseVttTime(s) {
  const m = /(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})/.exec(s || '');
  if (!m) return NaN;
  return parseInt(m[1] || '0', 10) * 3600 + parseInt(m[2], 10) * 60 + parseInt(m[3], 10) + parseInt(m[4].padEnd(3, '0'), 10) / 1000;
}

// Follows a WebVTT file while ffmpeg writes it, filing each finished cue at
// offsetSec + its own time. Returns a stop function that reads what's left
// and removes the file.
function followVtt(file, url, sub, offsetSec) {
  const store = subtitleTrackStore(url, sub);
  let pos = 0;
  let pending = '';
  let stopped = false;
  const drain = (final) => {
    let fd;
    try { fd = fs.openSync(file, 'r'); } catch { return; }
    try {
      const size = fs.fstatSync(fd).size;
      if (size > pos) {
        const buf = Buffer.alloc(size - pos);
        fs.readSync(fd, buf, 0, buf.length, pos);
        pos = size;
        pending += buf.toString('utf8');
      }
    } catch { /* try again on the next tick */ } finally {
      try { fs.closeSync(fd); } catch {}
    }
    pending = pending.replace(/\r\n/g, '\n');
    const blocks = pending.split(/\n{2,}/);
    pending = final ? '' : blocks.pop();
    for (const block of blocks) {
      const lines = block.split('\n');
      const at = lines.findIndex((l) => l.includes('-->'));
      if (at < 0) continue;
      const [a, b] = lines[at].split('-->');
      const start = parseVttTime(a) + offsetSec;
      const end = parseVttTime(b) + offsetSec;
      const text = lines.slice(at + 1).join('\n').trim();
      if (!isFinite(start) || !isFinite(end) || !text) continue;
      const key = `${Math.round(start * 5)}|${text}`;
      if (store.keys.has(key)) continue;
      store.keys.add(key);
      store.cues.push([Math.round(start * 1000) / 1000, Math.round(end * 1000) / 1000, text]);
    }
  };
  const timer = setInterval(() => drain(false), 700);
  return () => {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
    drain(true);
    try { fs.unlinkSync(file); } catch {}
  };
}

// ---- Where a seek really starts ----
//
// Copying video from a seek position can only begin at a keyframe, which is
// usually a couple of seconds before the requested point, and ffmpeg then
// numbers the output from zero. Placed at the requested time, the picture
// ran those seconds late — a short repeat after every seek, and subtitles
// out of step with it. A tiny extra output reports the first video packet's
// timestamp, so the response can say exactly where on the timeline its data
// belongs.
function startProbeOutput(url, mode) {
  const probed = probeCache.get(url);
  if (!probed || !probed.videoCodec) return null;
  if (mode !== 'copy' && mode !== 'audiofix') return null; // re-encoded video starts exactly at the seek point
  const file = path.join(cacheDir, `k-${crypto.randomBytes(6).toString('hex')}.txt`);
  return {
    file,
    args: ['-map', '0:v:0', '-c', 'copy', '-frames:v', '1', '-flush_packets', '1', '-f', 'framecrc', '-y', file]
  };
}

// Seconds relative to the seek point, or null while not written yet.
function readStartShift(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  const tb = /#tb 0:\s*(\d+)\/(\d+)/.exec(text);
  const pkt = /^0,\s*(-?\d+),/m.exec(text);
  if (!tb || !pkt) return null;
  return (parseInt(pkt[1], 10) * parseInt(tb[1], 10)) / parseInt(tb[2], 10);
}

// url -> the /probe answer. Probing costs a provider connection and a couple
// of seconds; the answer never changes, so a quality switch, a fallback or
// reopening the same film reuses it instead of asking again.
const probeCache = new Map();

// ---- One provider connection at a time ----
//
// IPTV accounts are commonly limited to a single simultaneous connection
// (this provider reports max_connections=1). Anything else still holding
// one — the cache download of a film that was just closed, the ffmpeg of a
// seek that has since been replaced, a probe — makes the provider refuse or
// throttle the stream the user is actually waiting for. That is what left
// seeks sitting on "connecting" and live channels buffering after a movie.
// So every provider connection is known here, and a new one first stops or
// pauses whatever it would compete with.
//
// Requests from the window carry a session id (`sid`) that grows with every
// playback it starts. Work tagged with an older id belongs to playback that
// has already been left, and is shut down as soon as a newer id shows up.
let latestSid = 0;
const providerHolders = new Set(); // { sid, kind: 'probe'|'seek'|'live', url, stop() }

function holdProvider(sid, kind, url, stopFn) {
  const holder = {
    sid, kind, url,
    stop: () => { providerHolders.delete(holder); try { stopFn(); } catch {} }
  };
  providerHolders.add(holder);
  return holder;
}

function suspendVodDownload(entry) { if (entry._downloadSuspend) entry._downloadSuspend(); }
function resumeVodDownload(entry) { if (entry._downloadResume) entry._downloadResume(); }

// False for a request belonging to playback that has already been replaced —
// it must not open anything.
function admitSession(sid) {
  if (!sid) return true; // debug pages and other untagged callers
  if (sid < latestSid) return false;
  if (sid > latestSid) {
    latestSid = sid;
    for (const h of [...providerHolders]) if (h.sid < sid) h.stop();
    for (const entry of vodCache.values()) if ((entry.sid || 0) < sid) suspendVodDownload(entry);
  }
  return true;
}

// Clears the way for a request about to use the provider for `url`. Only
// the cache download identified by keepKey (the one this request will read
// from) is allowed to keep going; every other download pauses and can pick
// up again later from where it stopped.
function yieldProvider(url, keepKey) {
  for (const h of [...providerHolders]) {
    if (h.kind === 'probe' && h.url === url) continue;
    h.stop();
  }
  for (const entry of vodCache.values()) {
    if (keepKey && entry.key === keepKey) resumeVodDownload(entry);
    else suspendVodDownload(entry);
  }
}

// Set while the window plays something straight from the provider without
// going through this proxy (live channels via hls.js, native MP4) — the
// proxy can't see that connection, so the window says so via /claim.
let externalPlaybackSid = 0;

// Is anything other than a download using the provider right now?
function providerBusyForDownloads() {
  if (externalPlaybackSid) return true;
  for (const h of providerHolders) if (h.kind !== 'download') return true;
  for (const entry of vodCache.values()) {
    if (!entry.done && !entry.suspended && entry.readers > 0) return true;
  }
  return false;
}

const { createDownloadManager } = require('./downloads');
const downloads = createDownloadManager({
  storeFile: path.join(userDataDir, 'downloads.json'),
  defaultDir: path.join(app.getPath('downloads'), 'MY IPTV'),
  hooks: {
    notify: (list) => {
      if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('downloads:update', list);
    },
    // A running download is one more holder of the provider connection, with
    // the lowest priority: anything that wants the connection for playback
    // stops it (it waits, and resumes afterwards).
    acquire: (url, onStop) => {
      const holder = holdProvider(Number.MAX_SAFE_INTEGER, 'download', url, onStop);
      return () => providerHolders.delete(holder);
    },
    isProviderBusy: providerBusyForDownloads
  }
});

// A file:// address of a finished download, as a local path — anything else
// (a file that isn't one of our downloads) is refused.
function localMediaPath(u) {
  if (!/^file:/i.test(u || '')) return null;
  try {
    const p = require('url').fileURLToPath(u);
    return downloads.isDownloadedFile(p) && fs.existsSync(p) ? p : null;
  } catch {
    return null;
  }
}

function stopAllProviderWork() {
  for (const h of [...providerHolders]) h.stop();
  for (const entry of vodCache.values()) suspendVodDownload(entry);
  for (const ff of activeProxies.values()) { try { ff.kill('SIGKILL'); } catch {} }
}

// ---- Output modes ----
//   copy       remux only — original quality, near-zero CPU
//   audiofix   video copied, audio re-encoded (AC3/EAC3/DTS have no decoder in Chromium)
//   transcode  everything re-encoded, for sources the browser can't decode at all
//   scaleN     re-encoded down to N lines tall (480, 720, ...) — a real lower
//              quality, chosen from the player's quality menu. Only ever
//              offered below the source's own height; nothing is upscaled.
function parseMode(value) {
  if (value === 'transcode' || value === 'audiofix') return value;
  const m = /^scale(\d{3,4})$/.exec(value || '');
  if (m) return `scale${Math.min(2160, Math.max(144, parseInt(m[1], 10)))}`;
  return 'copy';
}

// Re-encoded audio is mixed down to stereo. ffmpeg writes 5.1 AAC made from
// AC3/DTS (a "5.1(side)" layout) with a program config element instead of a
// standard channel configuration, and Chromium's MediaSource refuses to parse
// that at all — those films simply never started.
const AAC_ARGS = ['-c:a', 'aac', '-ac', '2'];

function codecArgsForMode(mode) {
  const scale = /^scale(\d+)$/.exec(mode);
  if (scale) {
    return ['-vf', `scale=-2:${scale[1]}`, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
      ...AAC_ARGS, '-b:a', '128k'];
  }
  if (mode === 'transcode') return ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', ...AAC_ARGS, '-b:a', '160k'];
  if (mode === 'audiofix') return ['-c:v', 'copy', ...AAC_ARGS, '-b:a', '160k'];
  return ['-c', 'copy'];
}

function startVodCacheEntry(url, mode, durationHint, audio = 0) {
  const key = cacheKeyFor(url, mode, audio);
  const filePath = path.join(cacheDir, `${key}.mp4`);
  // The real running time goes into the fragmented-MP4 header. It comes from
  // the window's probe (passed along with the request, and remembered here)
  // rather than a probe of our own: a second connection opened alongside the
  // download is exactly what a one-connection account refuses.
  const probed = probeCache.get(url);
  const entry = {
    key, url, sid: 0, filePath, bytesWritten: 0, done: false, failed: false,
    stderrTail: '', readers: 0, ff: null, idleKillTimer: null,
    failListeners: [], _downloadAbort: null, _contentLength: 0,
    startedAt: Date.now(), durationSec: (probed && probed.duration) || durationHint || 0
  };
  vodCache.set(key, entry);

  const outputArgs = [
    ...codecArgsForMode(mode),
    '-avoid_negative_ts', 'make_zero',
    '-f', 'mp4',
    '-movflags', 'frag_keyframe+empty_moov+delay_moov+default_base_moof',
    '-flush_packets', '1', // emit each fragment immediately instead of pooling
    'pipe:1'
  ];

  let ff;
  try {
    const inputArgs = [
      '-loglevel', 'error', '-nostdin',
      '-i', 'pipe:0',
      '-map', '0:v:0?', '-map', `0:a:${audio}?`,
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

  // Subtitles come from a second, lightweight ffmpeg fed the very same
  // downloaded bytes — no extra connection to the provider. They can't be
  // outputs of the ffmpeg above: next to its encoders, ffmpeg holds the
  // audio back waiting on the sparse subtitle streams.
  const subs = subtitleOutputs(url, key);
  let stopSubs = [];
  let subFf = null;
  if (subs.files.length) {
    try {
      subFf = spawn(ffmpegPath, ['-loglevel', 'error', '-nostdin', '-i', 'pipe:0', ...subs.args],
        { windowsHide: true, stdio: ['pipe', 'ignore', 'pipe'] });
      subFf.stdin.on('error', () => {});
      subFf.stderr.on('data', () => {});
      subFf.on('error', () => {});
      stopSubs = subs.files.map((x) => followVtt(x.file, url, x.sub, 0));
      subFf.on('close', () => stopSubs.forEach((stop) => stop()));
      entry.subFf = subFf;
    } catch {
      subFf = null;
    }
  }

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

  let dest = ff.stdin;
  if (subFf) {
    const { PassThrough } = require('stream');
    dest = new PassThrough({ highWaterMark: 1024 * 1024 });
    dest.pipe(ff.stdin);
    dest.on('data', (chunk) => { if (!subFf.stdin.destroyed) subFf.stdin.write(chunk); });
    dest.on('end', () => { try { subFf.stdin.end(); } catch {} });
  }
  downloadWithReconnect(url, dest, entry);

  return entry;
}

function downloadWithReconnect(originalUrl, dest, entry) {
  let totalDownloaded = 0;
  let closed = false;
  let suspended = false;
  let attempt = 0;        // bumped per request, so callbacks of an abandoned one do nothing
  let currentReq = null;
  let retryTimer = null;
  let failures = 0;
  let waitingForDrain = false;

  const gone = (id) => id !== attempt || closed || suspended || entry.done || (dest && dest.destroyed);

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

  // Providers answer a connection they consider one too many with 403, 458,
  // 509 and similar, and usually accept it a moment later once the previous
  // one is gone — so those, and dropped connections, are retried with a
  // backoff instead of failing the whole film.
  function scheduleReconnect(why) {
    if (closed || suspended || entry.done || (dest && dest.destroyed)) return;
    failures++;
    const limit = totalDownloaded > 0 ? 10 : 4;
    if (failures > limit) { failEntry(why); return; }
    const delayMs = Math.min(4000, 400 * failures);
    console.log(`[download] ${why} — retry ${failures}/${limit} in ${delayMs}ms (have ${totalDownloaded} bytes)`);
    clearTimeout(retryTimer);
    retryTimer = setTimeout(() => { retryTimer = null; fetchChunk(originalUrl, 0); }, delayMs);
  }

  function fetchChunk(url, depth) {
    if (closed || suspended || entry.done) return;
    const id = ++attempt;
    if (depth > 5) {
      console.error(`[download] too many redirects`);
      failEntry('Too many redirects');
      return;
    }

    let parsedUrl;
    try {
      parsedUrl = new URL(url);
    } catch {
      // A malformed url would otherwise throw straight out of the request
      // handler and take the whole app down with it.
      failEntry('Invalid stream URL');
      return;
    }
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
      if (gone(id)) { res.resume(); req.destroy(); return; }

      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        console.log(`[download] ${res.statusCode} redirect`);
        res.resume();
        let next;
        try { next = new URL(res.headers.location, url).href; } catch { failEntry('Bad redirect'); return; }
        fetchChunk(next, depth + 1);
        return;
      }

      if (res.statusCode !== 200 && res.statusCode !== 206) {
        console.error(`[download] HTTP ${res.statusCode}`);
        res.resume();
        if ([401, 403, 429, 458, 500, 502, 503, 504, 509].includes(res.statusCode)) {
          scheduleReconnect(`HTTP ${res.statusCode}`);
        } else {
          failEntry(`HTTP ${res.statusCode}`);
        }
        return;
      }

      // A server that ignores Range sends the whole file again from the
      // start; the part already written is skipped rather than duplicated.
      let skip = 0;
      if (res.statusCode === 206) {
        console.log(`[download] HTTP 206 resumed from ${totalDownloaded}`);
        if (!entry._contentLength) {
          const m = /\/(\d+)\s*$/.exec(res.headers['content-range'] || '');
          if (m) entry._contentLength = parseInt(m[1], 10);
        }
      } else {
        console.log(`[download] HTTP 200 content-length=${res.headers['content-length']}`);
        const cl = parseInt(res.headers['content-length'], 10);
        if (cl > 0) entry._contentLength = cl;
        skip = totalDownloaded;
      }

      res.on('data', (chunk) => {
        if (gone(id)) return;
        if (skip > 0) {
          if (chunk.length <= skip) { skip -= chunk.length; return; }
          chunk = chunk.subarray(skip);
          skip = 0;
        }
        totalDownloaded += chunk.length;
        failures = 0;
        let ok = true;
        try { ok = dest.write(chunk); } catch {}
        // Re-encoding modes can run slower than the network. Without
        // backpressure the whole film would pile up in memory.
        if (!ok && !waitingForDrain) {
          waitingForDrain = true;
          res.pause();
          dest.once('drain', () => { waitingForDrain = false; if (!gone(id)) res.resume(); });
        }
      });

      res.on('end', () => {
        if (gone(id)) return;
        const expected = entry._contentLength;
        if (expected && totalDownloaded < expected) {
          scheduleReconnect(`connection ended early at ${totalDownloaded}/${expected} bytes`);
          return;
        }
        console.log(`[download] complete, ${totalDownloaded} bytes`);
        tryClose();
      });

      res.on('error', (err) => {
        if (gone(id)) return;
        scheduleReconnect(`response error: ${err.message}`);
      });
    });
    currentReq = req;

    req.on('error', (err) => {
      if (gone(id)) return;
      scheduleReconnect(`request error: ${err.message}`);
    });

    req.on('timeout', () => {
      // An idle socket while ffmpeg catches up is expected, not a failure.
      if (waitingForDrain) return;
      console.error(`[download] timeout`);
      req.destroy(new Error('timeout'));
    });
  }

  entry._downloadAbort = () => {
    closed = true;
    clearTimeout(retryTimer);
    if (currentReq) { try { currentReq.destroy(); } catch {} }
    tryClose();
  };

  // Pausing hands the provider connection over to another request; ffmpeg
  // simply waits on its input meanwhile. Resuming continues with a Range
  // request from the byte where it stopped.
  entry._downloadSuspend = () => {
    if (closed || suspended || entry.done) return;
    suspended = true;
    entry.suspended = true;
    attempt++;
    clearTimeout(retryTimer);
    retryTimer = null;
    if (currentReq) { try { currentReq.destroy(); } catch {} currentReq = null; }
    console.log(`[download] paused at ${totalDownloaded} bytes`);
  };
  entry._downloadResume = () => {
    if (closed || !suspended || entry.done) return;
    suspended = false;
    entry.suspended = false;
    failures = 0;
    waitingForDrain = false;
    console.log(`[download] resuming at ${totalDownloaded} bytes`);
    fetchChunk(originalUrl, 0);
  };

  fetchChunk(originalUrl, 0);
}



function getOrCreateVodEntry(url, mode, durationHint, audio = 0) {
  const key = cacheKeyFor(url, mode, audio);
  const existing = vodCache.get(key);
  // Reuse a cache entry unless its ffmpeg process died with nothing to show.
  if (existing && !(existing.done && existing.failed)) {
    console.log(`[vod-cache] reusing existing entry mode=${mode} key=${key.slice(0, 8)} bytes=${existing.bytesWritten}`);
    return existing;
  }
  if (existing && existing.done && existing.failed) {
    console.log(`[vod-cache] previous entry FAILED, starting new one mode=${mode} stderr=${existing.stderrTail.slice(0, 200)}`);
  }
  return startVodCacheEntry(url, mode, durationHint, audio);
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
    // A seek drops the old /stream connection and opens a new one to the
    // same entry a moment later (client-side probe-skip + spawn + network
    // round trip) — 5s was too tight and this timer was winning the race,
    // deleting the still-useful cache file and forcing every seek to
    // re-download from byte 0. 25s comfortably covers a seek reconnect
    // while still cleaning up genuinely abandoned streams.
    entry.idleKillTimer = setTimeout(() => {
      if (entry.readers > 0) return;
      try { if (entry._downloadAbort) entry._downloadAbort(); } catch {}
      try { if (entry.ff) entry.ff.kill('SIGKILL'); } catch {}
      try { if (entry.subFf) entry.subFf.kill('SIGKILL'); } catch {}
      try { fs.unlinkSync(entry.filePath); } catch {}
      if (vodCache.get(entry.key) === entry) vodCache.delete(entry.key);
    }, 25000);
  }
}

// ---- Declaring the real running time in the fragmented-MP4 header ----
//
// ffmpeg's fragmented output carries no total duration: the header has an
// `mvex` box but no `mehd` inside it. A player therefore only knows about
// the part of the timeline it has already received, which has two nasty
// consequences here — it reports a ~30 second video, and, believing it has
// nearly all of it, stops reading ahead. Every seek past those few seconds
// then falls outside what it will accept and forces the stream to restart.
//
// Writing `mehd` ourselves fixes both: the player sees the full running
// time, buffers like a normal long video, and small seeks land inside what
// it already holds. ffmpeg offers no flag for this, so the box is inserted
// into the header as it streams past.
function insertMehd(moov, durationSec) {
  let timescale = 0;
  let mvexOff = -1;
  let mvexSize = 0;
  let off = 8;
  while (off + 8 <= moov.length) {
    const size = moov.readUInt32BE(off);
    const type = moov.toString('ascii', off + 4, off + 8);
    if (size < 8 || off + size > moov.length) break;
    if (type === 'mvhd') {
      const version = moov[off + 8];
      timescale = version === 1 ? moov.readUInt32BE(off + 28) : moov.readUInt32BE(off + 20);
    } else if (type === 'mvex') {
      mvexOff = off;
      mvexSize = size;
    }
    off += size;
  }
  if (!timescale || mvexOff < 0) return null;
  if (moov.toString('ascii', mvexOff + 8, mvexOff + 12) === 'mehd') return null; // already there

  const mehd = Buffer.alloc(16);
  mehd.writeUInt32BE(16, 0);
  mehd.write('mehd', 4, 'ascii');
  mehd.writeUInt32BE(0, 8); // version 0, no flags
  mehd.writeUInt32BE(Math.min(0xFFFFFFFE, Math.round(durationSec * timescale)), 12);

  const mvexHeader = Buffer.from(moov.subarray(mvexOff, mvexOff + 8));
  mvexHeader.writeUInt32BE(mvexSize + 16, 0);

  const out = Buffer.concat([
    moov.subarray(0, mvexOff),
    mvexHeader,
    mehd,
    moov.subarray(mvexOff + 8, mvexOff + mvexSize),
    moov.subarray(mvexOff + mvexSize)
  ]);
  out.writeUInt32BE(out.length, 0);
  return out;
}

// Returns the buffer with `mehd` inserted, or null while the moov box is
// still incomplete.
function patchMoovDuration(buf, durationSec) {
  let off = 0;
  while (off + 8 <= buf.length) {
    const size = buf.readUInt32BE(off);
    if (size < 8) return buf; // extended sizes aren't used here — pass through
    const type = buf.toString('ascii', off + 4, off + 8);
    if (type === 'moov') {
      if (off + size > buf.length) return null; // wait for the rest
      const patched = insertMehd(buf.subarray(off, off + size), durationSec);
      if (!patched) return buf;
      return Buffer.concat([buf.subarray(0, off), patched, buf.subarray(off + size)]);
    }
    off += size;
  }
  return null;
}

// Stream wrapper that rewrites the header as it goes by, then gets out of
// the way. Falls back to passing the bytes through untouched if the header
// can't be parsed or the duration never becomes known.
function mehdInjector(getDurationSec) {
  const { Transform } = require('stream');
  let head = Buffer.alloc(0);
  let passthrough = false;
  const started = Date.now();

  return new Transform({
    transform(chunk, enc, cb) {
      if (passthrough) { cb(null, chunk); return; }
      head = Buffer.concat([head, chunk]);

      const duration = getDurationSec();
      if (!duration) {
        // Duration comes from a probe running alongside playback; give it a
        // moment rather than emitting a header we can't complete.
        if (Date.now() - started < 5000 && head.length < 4 * 1024 * 1024) { cb(); return; }
        passthrough = true;
        const out = head; head = Buffer.alloc(0);
        cb(null, out);
        return;
      }

      const patched = patchMoovDuration(head, duration);
      if (patched === null) {
        if (head.length > 4 * 1024 * 1024) {
          passthrough = true;
          const out = head; head = Buffer.alloc(0);
          cb(null, out);
          return;
        }
        cb();
        return;
      }
      passthrough = true;
      head = Buffer.alloc(0);
      cb(null, patched);
    },
    flush(cb) {
      if (head && head.length) { const out = head; head = Buffer.alloc(0); cb(null, out); return; }
      cb();
    }
  });
}

// Plays from a seek position by pointing ffmpeg at the original URL with
// -ss. ffmpeg range-requests its way to that timestamp, so playback starts
// in seconds no matter how far in the position is — unlike the sequential
// cache, which would have to download everything before it first.
// inputPath: a local file to read instead of the provider (a download).
function serveDirectSeek(originalUrl, mode, seekSec, res, onDone, totalDurationSec, sid, audio = 0, headers = {}, inputPath = null) {
  let closed = false;
  let holder = null;
  let procs = [];
  let retryTimer = null;
  let stopSubs = [];
  const killAll = () => { for (const p of procs) { try { p.kill('SIGKILL'); } catch {} } };
  const cleanup = () => {
    if (holder) { providerHolders.delete(holder); holder = null; }
    clearTimeout(retryTimer);
    activeProxies.delete(res);
    stopSubs.forEach((stop) => stop());
    stopSubs = [];
    if (!closed) { closed = true; onDone(); }
  };

  const sink = mehdInjector(() => Math.max(0, (totalDurationSec || 0) - seekSec));
  const head = startHeadWriter(res, headers, seekSec);
  // A client that stops reading (MediaSource with a full buffer) pauses
  // ffmpeg all the way back, rather than the film piling up in memory here.
  sink.on('data', (chunk) => {
    if (!head.write(chunk)) {
      sink.pause();
      head.onDrain(() => sink.resume());
    }
  });
  sink.on('end', () => head.end());
  const finish = () => { if (!sink.writableEnded) sink.end(); cleanup(); };

  // Replaced by the next seek or playback: the connection is dropped rather
  // than ended cleanly, so nothing downstream mistakes it for the film's end.
  if (!inputPath) {
    holder = holdProvider(sid || 0, 'seek', originalUrl, () => {
      closed = true;
      clearTimeout(retryTimer);
      killAll();
      try { res.destroy(); } catch {}
      cleanup();
    });
  }

  const inputArgs = [
    ...(inputPath ? [] : [
      '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '4',
      '-user_agent', 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100'
    ]),
    '-ss', String(seekSec),
    '-i', inputPath || originalUrl
  ];
  const mp4Args = [
    '-avoid_negative_ts', 'make_zero',
    '-f', 'mp4',
    '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
    '-flush_packets', '1',
    'pipe:1'
  ];

  // Right after another connection to the provider closes, it can still
  // count that one for a moment and reset the new one. Nothing has been
  // sent at that point, so ffmpeg is simply started again after a short
  // pause instead of ending the response.
  const start = (attempt) => {
    if (closed || res.destroyed) return;
    let gotData = false;
    const tag = `seek-${crypto.randomBytes(6).toString('hex')}`;
    const subs = subtitleOutputs(originalUrl, tag);
    // Subtitles can come out of the same ffmpeg only while everything else
    // is copied. Next to an encoder, ffmpeg holds the encoded audio back
    // waiting on the (sparse) subtitle outputs, and the stream stalls. So
    // when re-encoding, a first ffmpeg copies the film out (subtitles go to
    // their files from there) and a second, local one does the encoding.
    const split = mode !== 'copy' && subs.files.length > 0;
    // The copied stream starts at a keyframe; so does the local encode fed
    // from it, which doesn't trim back to the seek point.
    const startOut = startProbeOutput(originalUrl, split ? 'copy' : mode);
    let out;
    try {
      if (!split) {
        const ff = spawn(ffmpegPath, [
          '-loglevel', 'error', '-nostdin',
          ...inputArgs,
          '-map', '0:v:0?', '-map', `0:a:${audio}?`,
          ...codecArgsForMode(mode),
          ...mp4Args,
          ...(startOut ? startOut.args : []),
          ...subs.args
        ], { windowsHide: true });
        procs = [ff];
        out = ff;
      } else {
        const copier = spawn(ffmpegPath, [
          '-loglevel', 'error', '-nostdin',
          ...inputArgs,
          '-map', '0:v:0?', '-map', `0:a:${audio}?`,
          '-c', 'copy',
          '-flush_packets', '1',
          '-f', 'matroska', 'pipe:1',
          ...(startOut ? startOut.args : []),
          ...subs.args
        ], { windowsHide: true });
        const encoder = spawn(ffmpegPath, [
          '-loglevel', 'error', '-nostdin',
          '-probesize', '1000000', '-analyzeduration', '1000000',
          '-i', 'pipe:0',
          '-map', '0:v?', '-map', '0:a?',
          ...codecArgsForMode(mode),
          ...mp4Args
        ], { windowsHide: true });
        copier.stdout.pipe(encoder.stdin);
        encoder.stdin.on('error', () => {});
        copier.on('close', () => { try { encoder.stdin.end(); } catch {} });
        copier.on('error', () => { try { encoder.stdin.end(); } catch {} });
        copier.stderr.on('data', (d) => {
          const msg = d.toString().trim();
          if (msg) console.error(`[seek-copy/${mode}] ${msg}`);
        });
        procs = [copier, encoder];
        out = encoder;
      }
    } catch {
      killAll();
      finish();
      return;
    }
    if (startOut) head.setStartFile(startOut.file);
    // Subtitle times in these outputs count from the seek point.
    stopSubs.push(...subs.files.map((x) => followVtt(x.file, originalUrl, x.sub, seekSec)));
    activeProxies.set(res, { kill: killAll });
    out.stdout.on('data', (chunk) => {
      gotData = true;
      if (!sink.write(chunk)) {
        out.stdout.pause();
        sink.once('drain', () => out.stdout.resume());
      }
    });
    out.stderr.on('data', (d) => {
      const msg = d.toString().trim();
      if (msg) console.error(`[seek-direct/${mode}] ${msg}`);
    });
    let ended = false;
    const onExit = () => {
      if (ended) return;
      ended = true;
      if (closed || res.destroyed) { killAll(); cleanup(); return; }
      if (!gotData && attempt < 3) {
        killAll();
        console.log(`[seek-direct/${mode}] no output from the source — retrying (${attempt + 1}/3)`);
        retryTimer = setTimeout(() => start(attempt + 1), 700 * (attempt + 1));
        return;
      }
      killAll();
      finish();
    };
    out.on('error', onExit);
    out.on('close', onExit);
  };

  res.on('close', () => {
    closed = true;
    clearTimeout(retryTimer);
    killAll();
    cleanup();
  });
  start(0);
}


// Holds the response headers back until the first bytes are ready, so they
// can carry X-Media-Start: where on the film's timeline this stream begins
// (see startProbeOutput). Waits briefly for that report once data flows;
// without one, the requested seek point is used.
function startHeadWriter(res, headers, seekSec) {
  let startFile = null;
  let sent = false;
  let queued = [];
  let ending = false;
  let waitTimer = null;
  const send = (startSec) => {
    if (sent || res.destroyed) return;
    sent = true;
    clearTimeout(waitTimer);
    if (startFile) { try { fs.unlinkSync(startFile); } catch {} }
    res.writeHead(200, Object.assign({}, headers, {
      'X-Media-Start': String(Math.max(0, startSec)),
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Expose-Headers': 'X-Media-Start'
    }));
    for (const chunk of queued) res.write(chunk);
    queued = [];
    if (ending && !res.writableEnded) res.end();
  };
  const trySend = (deadline) => {
    if (sent) return;
    const shift = startFile ? readStartShift(startFile) : 0;
    if (shift !== null) { send(seekSec + shift); return; }
    if (Date.now() >= deadline) { send(seekSec); return; }
    waitTimer = setTimeout(() => trySend(deadline), 25);
  };
  return {
    setStartFile(file) { startFile = file; },
    write(chunk) {
      if (res.destroyed) return true;
      if (sent) return res.write(chunk);
      queued.push(chunk);
      if (queued.length === 1) trySend(Date.now() + 2000);
      return true;
    },
    onDrain(fn) {
      if (sent && !res.destroyed) res.once('drain', fn);
      else fn();
    },
    end() {
      if (sent) { if (!res.writableEnded && !res.destroyed) res.end(); return; }
      ending = true;
      if (!queued.length) send(seekSec);
    }
  };
}



// Serves the cache from a seek position. ffmpeg is fed by a tailing reader
// rather than pointed at the file directly: given a plain path it stops at
// whatever end-of-file exists right then, ending the response seconds after
// a seek and leaving the browser with almost nothing buffered — so the next
// nudge forward needed yet another restart. Feeding it a pipe that keeps
// growing lets one ffmpeg run for the rest of playback.
//
// The output's timestamps restart at 0; the player adds its own seek offset
// back on for display.
function serveFromCacheFile(entry, seekSec, res, onDone, totalDurationSec, headers = {}) {
  let closed = false;
  const cleanup = () => { if (!closed) { closed = true; onDone(); } };
  res.on('close', cleanup);

  // This pass always copies, so it too starts at a keyframe before seekSec.
  const startOut = startProbeOutput(entry.url, 'copy');
  let ff;
  try {
    ff = spawn(ffmpegPath, [
      '-loglevel', 'error',
      '-ss', String(seekSec),
      '-i', 'pipe:0',
      '-map', '0:v?', '-map', '0:a?',
      '-c', 'copy',
      '-f', 'mp4',
      '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
      '-flush_packets', '1',
      'pipe:1',
      ...(startOut ? startOut.args : [])
    ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  } catch {
    if (!res.headersSent) res.writeHead(500);
    if (!res.writableEnded) res.end();
    cleanup();
    return;
  }

  const sink = mehdInjector(() => Math.max(0, (entry.durationSec || totalDurationSec || 0) - seekSec));
  const head = startHeadWriter(res, headers, seekSec);
  if (startOut) head.setStartFile(startOut.file);
  ff.stdout.pipe(sink);
  sink.on('data', (chunk) => {
    if (!head.write(chunk)) {
      sink.pause();
      head.onDrain(() => sink.resume());
    }
  });
  sink.on('end', () => head.end());
  ff.stderr.on('data', () => {});
  ff.stdin.on('error', () => {});
  ff.on('error', () => { head.end(); cleanup(); });
  ff.on('close', () => { if (!sink.writableEnded) sink.end(); cleanup(); });
  res.on('close', () => { try { ff.kill('SIGKILL'); } catch {} });

  // Feed from byte 0 — the fragmented-MP4 header lives at the front and
  // ffmpeg needs it before it can make sense of anything later in the file.
  // -ss then discards forward to the seek point.
  pipeGrowingFile(entry, ff.stdin, () => closed);
}


// Tails a still-growing cache file into a writable stream, waiting for more
// bytes whenever it catches up to the writer.
function pipeGrowingFile(entry, dest, isClosed) {
  let position = 0;
  const CHUNK = 1024 * 1024;
  let fd;
  try {
    fd = fs.openSync(entry.filePath, 'r');
  } catch {
    try { dest.end(); } catch {}
    return;
  }

  const finish = () => {
    try { fs.closeSync(fd); } catch {}
    try { dest.end(); } catch {}
  };

  function pump() {
    if (isClosed() || dest.destroyed) { finish(); return; }
    if (position >= entry.bytesWritten) {
      if (entry.done || entry.failed) { finish(); return; }
      setTimeout(pump, 100);
      return;
    }
    const toRead = Math.min(CHUNK, entry.bytesWritten - position);
    const buf = Buffer.alloc(toRead);
    fs.read(fd, buf, 0, toRead, position, (err, bytesRead) => {
      if (isClosed() || dest.destroyed) { finish(); return; }
      if (err || bytesRead <= 0) { finish(); return; }
      position += bytesRead;
      if (dest.write(buf.subarray(0, bytesRead))) pump();
      else dest.once('drain', pump);
    });
  }
  pump();
}

// Streams bytes [start, ) from a still-growing cache file, waiting for more
// data to be written if we catch up to the current end but ffmpeg isn't
// done yet — this is what lets playback start immediately while the rest
// keeps buffering in behind it, same as YouTube.
function serveGrowingFile(entry, start, res, onDone, totalDurationSec) {
  let position = start;
  let closed = false;
  // Everything written to `sink` reaches the client; the injector rewrites
  // the fragmented-MP4 header on its way past so the player learns the real
  // running time instead of guessing from what has arrived so far.
  const sink = mehdInjector(() => entry.durationSec || totalDurationSec || 0);
  sink.pipe(res, { end: false });
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
  sink.on('end', () => { if (!res.writableEnded) res.end(); });

  function pump() {
    if (closed) return;
    if (entry.failed && position >= entry.bytesWritten) {
      cleanup();
      sink.end();
      return;
    }
    if (position >= entry.bytesWritten) {
      if (entry.done) { cleanup(); sink.end(); return; }
      setTimeout(pump, 100);
      return;
    }
    const toRead = Math.min(CHUNK, entry.bytesWritten - position);
    const buf = Buffer.alloc(toRead);
    fs.read(fd, buf, 0, toRead, position, (err, bytesRead) => {
      if (closed) return;
      if (err || bytesRead <= 0) { cleanup(); sink.end(); return; }
      position += bytesRead;
      const ok = sink.write(buf.subarray(0, bytesRead));
      if (ok) pump();
      else sink.once('drain', pump);
    });
  }
  pump();
}

// Best-effort cleanup of the on-disk cache: on app quit, and any entry
// finished-and-unread for a while (guards against a very long session).
// With onlyIdle, anything a stream is reading right now is left alone —
// "Clear cache" in Settings shouldn't cut off the film that is playing.
function clearVodCache(onlyIdle) {
  for (const entry of [...vodCache.values()]) {
    if (onlyIdle && entry.readers > 0) continue;
    if (entry.idleKillTimer) { clearTimeout(entry.idleKillTimer); entry.idleKillTimer = null; }
    try { if (entry._downloadAbort) entry._downloadAbort(); } catch {}
    try { if (entry.ff) entry.ff.kill('SIGKILL'); } catch {}
    try { if (entry.subFf) entry.subFf.kill('SIGKILL'); } catch {}
    try { fs.unlinkSync(entry.filePath); } catch {}
    vodCache.delete(entry.key);
  }
}
app.on('before-quit', () => {
  downloads.shutdown();
  stopAllProviderWork();
  clearVodCache(false);
});
try {
  // Wipe any leftovers from a previous crashed/killed session.
  for (const f of fs.readdirSync(cacheDir)) {
    try { fs.unlinkSync(path.join(cacheDir, f)); } catch {}
  }
} catch {}

function isPlayableUrl(u) {
  try {
    const p = new URL(u);
    return p.protocol === 'http:' || p.protocol === 'https:';
  } catch {
    return false;
  }
}

function startProxyServer() {
  const handleRequest = (req, res) => {
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

    // Serves the real player module so the MediaSource path can be exercised
    // against this proxy from a browser tab, where its failures are visible.
    if (parsed.pathname === '/msejs') {
      try {
        const js = fs.readFileSync(path.join(__dirname, 'src', 'mse.js'), 'utf-8');
        res.writeHead(200, { 'Content-Type': 'application/javascript', 'Cache-Control': 'no-store' });
        res.end(js);
      } catch (err) {
        res.writeHead(500).end(String(err));
      }
      return;
    }

    if (parsed.pathname === '/msetest') {
      const target = parsed.searchParams.get('url') || '';
      const mode = parsed.searchParams.get('mode') || 'copy';
      const dur = parsed.searchParams.get('dur') || '0';
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(`<!DOCTYPE html><html><body style="background:#000;color:#0f0;font-family:monospace">
        <video id="v" controls style="width:60%"></video><pre id="log"></pre>
        <script src="/msejs"></script>
        <script>
          window.__log = [];
          const say = (m) => { window.__log.push(m); document.getElementById('log').textContent += m + '\\n'; };
          const v = document.getElementById('v');
          ['loadedmetadata','canplay','playing','error','stalled','waiting'].forEach(ev =>
            v.addEventListener(ev, () => say('EVENT ' + ev + (v.error ? ' code=' + v.error.code + ' ' + v.error.message : ''))));
          window.__s = new MseVodStreamer(v);
          window.__s.onFatal = (e) => say('FATAL ' + (e && e.message));
          window.__s.start({
            buildUrl: (sec) => '/stream?url=${encodeURIComponent(target)}&mode=${mode}&live=0&seek=' + sec + '&dur=${dur}&t=' + Date.now(),
            duration: ${parseFloat(dur) || 0},
            startAt: 0
          }).then(() => { say('START OK'); v.play().catch(e => say('play() ' + e.message)); })
            .catch((e) => say('START FAILED ' + (e && e.message)));
        </script>
      </body></html>`);
      return;
    }

    if (parsed.pathname === '/thumb') {
      const target = parsed.searchParams.get('url');
      const w = Math.min(600, Math.max(80, parseInt(parsed.searchParams.get('w') || '300', 10) || 300));
      if (!isPlayableUrl(target)) { res.writeHead(400).end('Bad url'); return; }

      const key = crypto.createHash('sha1').update(`${w}:${target}`).digest('hex');
      const file = path.join(thumbDir, `${key}.jpg`);
      // Anything that goes wrong — unreachable host, an image ffmpeg can't
      // read — falls back to the original URL so the grid still shows art.
      const fallback = () => { if (!res.headersSent) res.writeHead(302, { Location: target }); res.end(); };
      const headers = { 'Content-Type': 'image/jpeg', 'Cache-Control': 'public, max-age=31536000' };

      if (fs.existsSync(file)) {
        res.writeHead(200, headers);
        fs.createReadStream(file).on('error', fallback).pipe(res);
        return;
      }

      // Nothing cached yet: fetch the original here and pass the bytes
      // straight through, then build the small copy in the background for
      // next time.
      //
      // Redirecting the window to the image host instead looks simpler, but
      // this app's renderer cannot complete TLS handshakes to many of them
      // (the log fills with handshake failures) — every poster then hung
      // pending and the grid stayed empty, even though fetching the very
      // same URL from this process works. Keeping artwork on plain local
      // HTTP sidesteps that entirely.
      //
      // Artwork that just failed (dead host, 404) is answered straight away
      // for a while, so a grid full of broken links doesn't tie up the
      // browser's few connections waiting on timeouts.
      const failedAt = thumbFailures.get(target);
      if (failedAt && Date.now() - failedAt < 10 * 60 * 1000) {
        res.writeHead(404, { 'Cache-Control': 'no-store' });
        res.end();
        return;
      }
      const source = sizedArtworkUrl(target, w);
      let fetchHandle = null;
      let clientGone = false;
      const deliver = (err, buf) => {
        if (clientGone || res.writableEnded || res.destroyed) return;
        if (err || !buf || !buf.length) {
          thumbFailures.set(target, Date.now());
          if (thumbFailures.size > 5000) thumbFailures.delete(thumbFailures.keys().next().value);
          res.writeHead(404, { 'Cache-Control': 'no-store' });
          res.end();
          return;
        }
        res.writeHead(200, { 'Content-Type': guessImageType(target, buf), 'Cache-Control': 'no-store' });
        res.end(buf);
        queueThumbBuild(target, w, file, key, buf);
      };
      fetchHandle = fetchImage(source, 0, (err, buf) => {
        // The smaller size missing is unusual, but the original still works.
        if ((err || !buf || !buf.length) && source !== target && !clientGone) {
          fetchHandle = fetchImage(target, 0, deliver);
          return;
        }
        deliver(err, buf);
      });
      // The poster scrolled away and the page dropped the request — stop
      // downloading it rather than spending bandwidth on something unseen.
      res.on('close', () => {
        if (res.writableEnded) return;
        clientGone = true;
        if (fetchHandle) fetchHandle.abort();
      });
      return;
    }

    // The window leaving playback (or starting a new one) — everything that
    // belonged to earlier playback lets go of the provider right away,
    // instead of the old film's download lingering and crowding out whatever
    // plays next.
    if (parsed.pathname === '/release') {
      const sid = parseFloat(parsed.searchParams.get('sid')) || 0;
      if (sid) admitSession(sid);
      if (externalPlaybackSid && externalPlaybackSid < sid) externalPlaybackSid = 0;
      downloads.playbackEnded();
      res.writeHead(204, { 'Cache-Control': 'no-store' });
      res.end();
      return;
    }

    // The window is about to play something from the provider: downloads
    // step aside until it's done.
    if (parsed.pathname === '/claim') {
      const sid = parseFloat(parsed.searchParams.get('sid')) || 0;
      if (sid && admitSession(sid)) externalPlaybackSid = Math.max(externalPlaybackSid, sid);
      downloads.pauseForPlayback();
      res.writeHead(204, { 'Cache-Control': 'no-store' });
      res.end();
      return;
    }

    // Subtitle cues collected so far for one track of a film. `after` skips
    // the ones the window already has.
    if (parsed.pathname === '/subs') {
      const target = parsed.searchParams.get('url') || '';
      const sub = parseInt(parsed.searchParams.get('sub') || '0', 10) || 0;
      const after = Math.max(0, parseInt(parsed.searchParams.get('after') || '0', 10) || 0);
      const byUrl = subtitleStore.get(target);
      const track = byUrl && byUrl.get(sub);
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ total: track ? track.cues.length : 0, cues: track ? track.cues.slice(after) : [] }));
      return;
    }

    if (parsed.pathname === '/probe') {
      const target = parsed.searchParams.get('url');
      const localPath = localMediaPath(target);
      if (!localPath && !isPlayableUrl(target)) { res.writeHead(400).end('Bad url'); return; }
      const sid = parseFloat(parsed.searchParams.get('sid')) || 0;
      if (!admitSession(sid)) { res.writeHead(410).end('Superseded'); return; }
      const sendJson = (obj) => {
        if (res.writableEnded) return;
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(JSON.stringify(obj));
      };
      if (probeCache.has(target)) { sendJson(probeCache.get(target)); return; }
      if (!localPath) yieldProvider(target, null);
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
        // Duration and codec names live in the container header, so there's
        // no reason to pull the default 5MB before answering.
        '-probesize', '1000000', '-analyzeduration', '1000000',
        '-show_entries', 'format=duration:stream=codec_type,codec_name,width,height,channels:stream_tags=language,title:stream_disposition=default,forced',
        '-of', 'json',
        localPath || target
      ];
      const ffprobePath = ffmpegPath.replace(/ffmpeg(\.exe)?$/i, (m, ext) => `ffprobe${ext || ''}`);
      const empty = { duration: null, videoCodec: null, audioCodec: null };
      let fp;
      try {
        fp = spawn(ffprobePath, probeArgs, { windowsHide: true });
      } catch {
        sendJson(empty);
        return;
      }
      const holder = holdProvider(sid, 'probe', target, () => { try { fp.kill('SIGKILL'); } catch {} });
      res.on('close', () => { if (!res.writableEnded) holder.stop(); });
      let out = '';
      fp.stdout.on('data', (d) => { out += d; });
      fp.stderr.on('data', () => {});
      fp.on('close', () => {
        providerHolders.delete(holder);
        try {
          const parsed2 = JSON.parse(out);
          const duration = parseFloat(parsed2.format && parsed2.format.duration);
          const streams = parsed2.streams || [];
          const videoCodec = (streams.find((s) => s.codec_type === 'video') || {}).codec_name || null;
          const audioCodec = (streams.find((s) => s.codec_type === 'audio') || {}).codec_name || null;
          const vs = streams.find((s) => s.codec_type === 'video') || {};
          const width = parseInt(vs.width, 10) || null;
          const height = parseInt(vs.height, 10) || null;
          const tag = (st, name) => (st.tags && (st.tags[name] || st.tags[name.toUpperCase()])) || '';
          const audioTracks = streams.filter((st) => st.codec_type === 'audio').map((st, index) => ({
            index, codec: st.codec_name || '', lang: tag(st, 'language'), title: tag(st, 'title'),
            channels: st.channels || 0, default: !!(st.disposition && st.disposition.default)
          }));
          const subtitleTracks = streams.filter((st) => st.codec_type === 'subtitle').map((st, index) => ({
            index, codec: st.codec_name || '', lang: tag(st, 'language'), title: tag(st, 'title'),
            forced: !!(st.disposition && st.disposition.forced),
            text: TEXT_SUBTITLE_CODECS.has(st.codec_name || '')
          }));
          const result = { duration: isFinite(duration) ? duration : null, videoCodec, audioCodec, width, height, audioTracks, subtitleTracks };
          if (result.duration) {
            probeCache.set(target, result);
            if (probeCache.size > 300) probeCache.delete(probeCache.keys().next().value);
          }
          sendJson(result);
        } catch {
          sendJson(empty);
        }
      });
      fp.on('error', () => { providerHolders.delete(holder); sendJson(empty); });
      return;
    }

    if (parsed.pathname === '/vod-progress') {
      // Reports how much of the ORIGINAL file is actually cached on disk,
      // independent of which part of it the <video> element currently has
      // loaded. The player's buffered-range bar can't get this from
      // video.buffered alone: after a seek, that only covers the fragment
      // being served *from* the seek point forward, not the 0..seekPoint
      // span that was already downloaded earlier — exactly the gap that
      // made the "YouTube-style" buffered line look wrong post-seek.
      const target = parsed.searchParams.get('url');
      const modeParam = parsed.searchParams.get('mode');
      const mode = parseMode(modeParam);
      if (!isPlayableUrl(target)) { res.writeHead(400).end('Bad url'); return; }
      const key = cacheKeyFor(target, mode);
      const entry = vodCache.get(key);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      if (!entry) {
        res.end(JSON.stringify({ bytesWritten: 0, contentLength: 0, done: false }));
      } else {
        res.end(JSON.stringify({ bytesWritten: entry.bytesWritten, contentLength: entry._contentLength || 0, done: entry.done }));
      }
      return;
    }

    if (parsed.pathname !== '/stream') {
      res.writeHead(404).end('Not found');
      return;
    }

    const target = parsed.searchParams.get('url');
    const modeParam = parsed.searchParams.get('mode');
    const mode = parseMode(modeParam);
    const isLive = parsed.searchParams.get('live') === '1';
    const seekSec = Math.max(0, parseFloat(parsed.searchParams.get('seek') || '0') || 0);
    const totalDurationSec = Math.max(0, parseFloat(parsed.searchParams.get('dur') || '0') || 0);
    const sid = parseFloat(parsed.searchParams.get('sid')) || 0;
    // MediaSource reads the body itself and needs no length; a guessed one
    // only hurts there (the real remuxed size never matches it exactly).
    const forMse = parsed.searchParams.get('mse') === '1';
    // Which of the film's audio tracks to play (0 = the first).
    const audio = Math.max(0, parseInt(parsed.searchParams.get('audio') || '0', 10) || 0);
    const localPath = isLive ? null : localMediaPath(target);
    if (!localPath && !isPlayableUrl(target)) {
      res.writeHead(400).end('Bad url');
      return;
    }
    if (!admitSession(sid)) {
      res.writeHead(410, { 'Cache-Control': 'no-store' }).end('Superseded');
      return;
    }

    // A downloaded film: ffmpeg reads the file directly and can jump
    // anywhere in it at once, so there's no cache and no provider to share.
    if (localPath) {
      const headers = { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' };
      const durationSec = totalDurationSec || (probeCache.get(target) || {}).duration || 0;
      serveDirectSeek(target, mode, seekSec, res, () => {}, durationSec, sid, audio, headers, localPath);
      return;
    }

    if (!isLive) {
      // VOD: serve the growing cache file as a plain, sequential 200 stream.
      //
      // Do NOT advertise Range/206 here. It looks like the obvious way to get
      // instant seeking, but this file is a fragmented MP4 with no index:
      // once the pipeline believes the source is seekable, ffmpeg's mov
      // demuxer scans every fragment in the file before it will report
      // metadata. On a file that is still downloading that scan never
      // finishes — the browser fires loadstart and then sits there forever,
      // re-reading at the download head, and no frame ever plays. Served as
      // a stream instead, fragments get parsed as they arrive. Seeking is
      // handled by seekTo() restarting ffmpeg at the target timestamp.
      const key = cacheKeyFor(target, mode, audio);
      const durationSec = totalDurationSec || (probeCache.get(target) || {}).duration || 0;

      if (seekSec > 0) {
        const existing = vodCache.get(key);
        const entry = existing && !(existing.done && existing.failed) ? existing : null;

        // How far into the file a seek target lands, in bytes. The video's
        // own average bitrate is fileSize/duration, so seeking to `sec` needs
        // about (sec/duration)*fileSize on disk.
        let ready = false;
        let need = null;
        if (entry && entry.bytesWritten > 0) {
          if (entry.done) ready = true;
          else if (durationSec && entry._contentLength) {
            need = Math.min(entry._contentLength, (seekSec / durationSec) * entry._contentLength * 1.10);
            ready = entry.bytesWritten >= need;
          }
        }

        if (entry) addVodReader(entry);
        let released = false;
        const release = () => { if (!released) { released = true; if (entry) releaseVodReader(entry); } };
        res.on('close', release);

        // Declaring a length matters more than its precision for a plain
        // <video>: without one Chromium treats the response as a live stream
        // and keeps only a few seconds buffered ahead. MediaSource doesn't
        // need it.
        const seekHeaders = { 'Content-Type': 'video/mp4', 'Cache-Control': 'no-store' };
        const sourceSize = (entry && entry._contentLength) || 0;
        if (!forMse && durationSec > 0 && sourceSize > 0 && seekSec < durationSec) {
          const remaining = Math.floor(sourceSize * (1 - seekSec / durationSec));
          if (remaining > 0) seekHeaders['Content-Length'] = remaining;
        }
        if (ready) {
          console.log(`[stream] seek=${seekSec.toFixed(1)}s from cache (${(entry.bytesWritten / 1048576).toFixed(1)}MB on disk)`);
          entry.sid = Math.max(entry.sid || 0, sid);
          yieldProvider(target, key);
          serveFromCacheFile(entry, seekSec, res, release, durationSec, seekHeaders);
        } else {
          // The cache fills strictly front-to-back, so a position it hasn't
          // reached (or a stream with no cache at all yet — a quality switch,
          // a resume) is read straight from the source with -ss. The cache
          // download pauses meanwhile: the account allows one connection, and
          // this is the one being watched.
          console.log(`[stream] seek=${seekSec.toFixed(1)}s at source (cache ${entry ? (entry.bytesWritten / 1048576).toFixed(1) : 0}MB, need~${need ? (need / 1048576).toFixed(1) : '?'}MB)`);
          yieldProvider(target, null);
          serveDirectSeek(target, mode, seekSec, res, release, (entry && entry.durationSec) || durationSec, sid, audio, seekHeaders);
        }
        return;
      }

      yieldProvider(target, key);
      const entry = getOrCreateVodEntry(target, mode, durationSec, audio);
      entry.sid = Math.max(entry.sid || 0, sid);
      resumeVodDownload(entry);

      addVodReader(entry);
      let aborted = false;
      let released = false;
      let pollTimer = null;
      let served = false;
      const release = () => { if (!released) { released = true; releaseVodReader(entry); } };
      res.on('close', () => { aborted = true; if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } release(); });

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
          console.log(`[stream] start cache=${(entry.bytesWritten / 1048576).toFixed(1)}MB`);
          const initHeaders = {
            'Content-Type': 'video/mp4', 'Cache-Control': 'no-store',
            'X-Media-Start': '0', 'Access-Control-Allow-Origin': '*', 'Access-Control-Expose-Headers': 'X-Media-Start'
          };
          if (!forMse && entry._contentLength > 0) initHeaders['Content-Length'] = entry._contentLength;
          res.writeHead(200, initHeaders);
          serveGrowingFile(entry, 0, res, release, durationSec);
        } catch { /* client already gone */ }
      };
      waitThenServe();
      return;
    }

    yieldProvider(target, null);

    const commonArgs = [
      '-loglevel', 'error',
      '-nostdin',
      '-reconnect', '1', '-reconnect_streamed', '1', '-reconnect_delay_max', '4',
      // Without this, a one-connection account that's still counting the
      // browser's just-closed HLS connection against the limit makes ffmpeg
      // hang on connect forever — no data, no error, no timeout — instead
      // of the request failing so the client's own retry logic can kick in.
      '-rw_timeout', '12000000',
      '-user_agent', 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100',
      '-i', target,
      '-map', '0:v:0?',
      '-map', '0:a:0?'
    ];

    const outArgs = codecArgsForMode(mode);

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
    const holder = holdProvider(sid, 'live', target, () => {
      try { ff.kill('SIGKILL'); } catch {}
      try { res.destroy(); } catch {}
    });
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
      providerHolders.delete(holder);
      if (res.destroyed) return;
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
      providerHolders.delete(holder);
      if (!headerWritten && !res.destroyed) {
        res.writeHead(500).end('ffmpeg spawn error: ' + err.message);
      }
    });

    res.on('close', () => {
      providerHolders.delete(holder);
      if (activeProxies.has(res)) {
        try { ff.kill('SIGKILL'); } catch {}
        activeProxies.delete(res);
      }
    });
  };

  const server = http.createServer(handleRequest);
  // Thumbnails get their own ports on purpose. Chromium allows only six
  // connections per origin: sharing the stream's port, a grid asking for a
  // hundred posters would queue up in front of the video's own requests and
  // stall playback. Several ports, too, because six at a time is also what
  // made a big grid fill in so slowly — each port is its own origin with its
  // own six.
  const THUMB_SERVERS = 4;
  const thumbServers = Array.from({ length: THUMB_SERVERS }, () => http.createServer(handleRequest));

  const listen = (srv) => new Promise((resolve) => srv.listen(0, '127.0.0.1', () => resolve(srv.address().port)));
  return listen(server).then(async (port) => {
    proxyPort = port;
    thumbPorts = [];
    for (const srv of thumbServers) thumbPorts.push(await listen(srv));
    console.log(`[proxy] stream port=${proxyPort} thumb ports=${thumbPorts.join(',')}`);
    return server;
  });
}

ipcMain.handle('proxy:getBase', () => {
  return proxyPort ? `http://127.0.0.1:${proxyPort}` : null;
});

ipcMain.handle('proxy:getThumbBase', () => {
  return thumbPorts.length ? `http://127.0.0.1:${thumbPorts[0]}` : null;
});

ipcMain.handle('proxy:getThumbBases', () => thumbPorts.map((p) => `http://127.0.0.1:${p}`));


ipcMain.handle('catalog:get', () => {
  try {
    return JSON.parse(fs.readFileSync(catalogFile, 'utf-8'));
  } catch {
    return null;
  }
});

ipcMain.handle('catalog:set', (_e, data) => {
  try {
    if (data === null) fs.unlinkSync(catalogFile);
    else fs.writeFileSync(catalogFile, JSON.stringify(data), 'utf-8');
  } catch { /* a missing catalog just means the next launch reloads it */ }
  return true;
});

ipcMain.handle('cache:info', () => {
  let files = 0;
  let bytes = 0;
  for (const dir of [cacheDir, thumbDir]) {
    try {
      for (const f of fs.readdirSync(dir)) {
        try { bytes += fs.statSync(path.join(dir, f)).size; files++; } catch {}
      }
    } catch {}
  }
  return { files, bytes };
});

ipcMain.handle('cache:clear', () => {
  clearVodCache(true);
  const inUse = new Set([...vodCache.values()].map((e) => path.basename(e.filePath)));
  for (const dir of [cacheDir, thumbDir]) {
    try {
      for (const f of fs.readdirSync(dir)) {
        if (dir === cacheDir && inUse.has(f)) continue;
        try { fs.unlinkSync(path.join(dir, f)); } catch {}
      }
    } catch {}
  }
  return true;
});

ipcMain.handle('app:getVersion', () => app.getVersion());

// ---- Downloads ----
ipcMain.handle('downloads:list', () => downloads.list());
ipcMain.handle('downloads:add', (_e, meta) => {
  try { return { ok: true, item: downloads.add(meta) }; } catch (err) { return { ok: false, error: err.message }; }
});
ipcMain.handle('downloads:pause', (_e, id) => downloads.pause(id));
ipcMain.handle('downloads:resume', (_e, id) => downloads.resume(id));
ipcMain.handle('downloads:remove', (_e, id, deleteFile) => downloads.remove(id, !!deleteFile));
ipcMain.handle('downloads:getDir', () => downloads.getDir());
ipcMain.handle('downloads:setConcurrent', (_e, on) => { downloads.setConcurrent(!!on); return true; });
ipcMain.handle('downloads:chooseDir', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: 'Choose where downloads are saved',
    defaultPath: downloads.getDir(),
    properties: ['openDirectory', 'createDirectory']
  });
  if (result.canceled || !result.filePaths || !result.filePaths[0]) return { ok: false, dir: downloads.getDir() };
  try {
    return { ok: true, dir: downloads.setDir(result.filePaths[0]) };
  } catch (err) {
    return { ok: false, dir: downloads.getDir(), error: `That folder can't be written to (${err.message}).` };
  }
});
ipcMain.handle('downloads:openFolder', (_e, id) => {
  const item = id ? downloads.get(id) : null;
  if (item && item.status === 'completed' && fs.existsSync(item.filePath)) shell.showItemInFolder(item.filePath);
  else {
    try { fs.mkdirSync(downloads.getDir(), { recursive: true }); } catch {}
    shell.openPath(downloads.getDir());
  }
  return true;
});
ipcMain.handle('downloads:fileUrl', (_e, id) => {
  const item = downloads.get(id);
  if (!item || item.status !== 'completed' || !fs.existsSync(item.filePath)) return null;
  return require('url').pathToFileURL(item.filePath).href;
});

// Brings the app back in front, e.g. when the picture-in-picture window's
// "back to tab" button is used. Chromium only refocuses its tab, which
// doesn't raise an Electron window that is minimised or behind others.
// Windows refuses a plain focus() from a background app, so the window is
// briefly pinned on top to get past that.
ipcMain.handle('window:focus', () => {
  if (!mainWindow || mainWindow.isDestroyed()) return false;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.setAlwaysOnTop(true);
  mainWindow.moveTop();
  mainWindow.focus();
  setTimeout(() => { if (mainWindow && !mainWindow.isDestroyed()) mainWindow.setAlwaysOnTop(false); }, 250);
  return true;
});
