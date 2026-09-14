// Downloads films and episodes to disk for watching offline.
//
// One download runs at a time, over one connection, as fast as that
// connection goes: the provider allows a single connection per account, so
// splitting a file into parallel ranges (or running several downloads side
// by side) gets connections refused rather than making anything faster.
// For the same reason a download normally steps aside while something is
// being watched from the provider, and carries on by itself afterwards —
// unless downloading alongside playback has been allowed (setConcurrent),
// for accounts with more than one connection.
//
// Data is written to "<name>.part" and renamed when complete, so an
// interrupted download — a dropped connection, closing the app — picks up
// from the byte where it stopped.
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const crypto = require('crypto');

const USER_AGENT = 'VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100';
const RETRYABLE_STATUS = new Set([401, 403, 408, 429, 458, 500, 502, 503, 504, 509]);

function safeName(value) {
  const cleaned = String(value || '')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/, '');
  return cleaned.slice(0, 140) || 'video';
}

function createDownloadManager({ storeFile, defaultDir, hooks }) {
  let data = load();
  let active = null;          // { item, req, file, windowBytes, windowStart, retryTimer }
  let playbackActive = false; // someone is watching from the provider
  let concurrent = false;     // keep downloading while something plays
  let resumeTimer = null;
  let saveTimer = null;
  let ticker = null;
  const speeds = new Map();   // id -> bytes per second (smoothed)

  function load() {
    try {
      const d = JSON.parse(fs.readFileSync(storeFile, 'utf8'));
      const items = Array.isArray(d.items) ? d.items : [];
      // Whatever was running when the app last closed goes back in line.
      for (const it of items) if (it.status === 'downloading' || it.status === 'waiting') it.status = 'queued';
      return { dir: d.dir || defaultDir, items };
    } catch {
      return { dir: defaultDir, items: [] };
    }
  }

  function saveNow() {
    clearTimeout(saveTimer);
    saveTimer = null;
    try {
      fs.mkdirSync(path.dirname(storeFile), { recursive: true });
      fs.writeFileSync(storeFile, JSON.stringify(data, null, 1), 'utf8');
    } catch { /* retried on the next change */ }
  }
  function saveSoon() {
    if (!saveTimer) saveTimer = setTimeout(saveNow, 3000);
  }

  function view(item) {
    const speed = speeds.get(item.id) || 0;
    const remaining = item.totalBytes ? Math.max(0, item.totalBytes - item.receivedBytes) : 0;
    return Object.assign({}, item, {
      speed: item.status === 'downloading' ? speed : 0,
      eta: item.status === 'downloading' && speed > 0 && item.totalBytes ? remaining / speed : null,
      progress: item.totalBytes ? Math.min(1, item.receivedBytes / item.totalBytes) : (item.status === 'completed' ? 1 : 0)
    });
  }

  function list() { return data.items.map(view); }

  function changed(immediate) {
    if (immediate) saveNow(); else saveSoon();
    try { hooks.notify(list()); } catch {}
  }

  function find(id) { return data.items.find((it) => it.id === id); }

  function uniquePath(p) {
    if (!fs.existsSync(p) && !fs.existsSync(`${p}.part`)) return p;
    const ext = path.extname(p);
    const base = p.slice(0, p.length - ext.length);
    for (let n = 2; n < 1000; n++) {
      const candidate = `${base} (${n})${ext}`;
      if (!fs.existsSync(candidate) && !fs.existsSync(`${candidate}.part`)) return candidate;
    }
    return `${base} ${Date.now()}${ext}`;
  }

  function targetPath(meta) {
    const ext = safeName(meta.ext || 'mp4').replace(/\s/g, '').toLowerCase() || 'mp4';
    if (meta.type === 'episode') {
      const series = safeName(meta.seriesName || meta.title);
      const m = /Season\s+(\d+)\s*-\s*Episode\s+(\d+)\s*(?:-\s*(.*))?$/i.exec(meta.subtitle || '');
      const tag = m ? `S${m[1].padStart(2, '0')}E${m[2].padStart(2, '0')}` : '';
      const epTitle = m && m[3] ? ` - ${m[3]}` : (meta.subtitle ? ` - ${meta.subtitle}` : '');
      return path.join(data.dir, series, `${safeName(`${series}${tag ? ` - ${tag}` : ''}${epTitle}`)}.${ext}`);
    }
    return path.join(data.dir, `${safeName(meta.title)}.${ext}`);
  }

  function add(meta) {
    if (!meta || !/^https?:\/\//i.test(meta.url || '')) throw new Error('This item cannot be downloaded.');
    const existing = data.items.find((it) => it.url === meta.url && it.status !== 'failed');
    if (existing) return view(existing);
    const failed = data.items.find((it) => it.url === meta.url);
    if (failed) { failed.status = 'queued'; failed.error = ''; changed(true); pump(); return view(failed); }

    const filePath = uniquePath(targetPath(meta));
    const item = {
      id: crypto.randomBytes(8).toString('hex'),
      url: meta.url,
      title: meta.title || 'Video',
      subtitle: meta.subtitle || '',
      type: meta.type === 'episode' ? 'episode' : 'movie',
      seriesName: meta.seriesName || '',
      thumb: meta.thumb || '',
      filePath,
      totalBytes: 0,
      receivedBytes: 0,
      status: 'queued',
      error: '',
      addedAt: Date.now(),
      completedAt: 0
    };
    data.items.unshift(item);
    changed(true);
    pump();
    return view(item);
  }

  function stopActive(nextStatus) {
    if (!active) return;
    const a = active;
    active = null;
    clearTimeout(a.retryTimer);
    if (a.release) { try { a.release(); } catch {} }
    try { if (a.req) a.req.destroy(); } catch {}
    try { if (a.file) a.file.end(); } catch {}
    speeds.delete(a.item.id);
    if (nextStatus) a.item.status = nextStatus;
  }

  function pause(id) {
    const item = find(id);
    if (!item || item.status === 'completed') return list();
    if (active && active.item === item) stopActive('paused');
    else item.status = 'paused';
    changed(true);
    pump();
    return list();
  }

  function resume(id) {
    const item = find(id);
    if (!item || item.status === 'completed' || item.status === 'downloading') return list();
    item.status = 'queued';
    item.error = '';
    changed(true);
    pump();
    return list();
  }

  function remove(id, deleteFile) {
    const item = find(id);
    if (!item) return list();
    if (active && active.item === item) stopActive(null);
    try { fs.unlinkSync(`${item.filePath}.part`); } catch {}
    if (deleteFile || item.status !== 'completed') { try { fs.unlinkSync(item.filePath); } catch {} }
    data.items = data.items.filter((it) => it !== item);
    speeds.delete(id);
    changed(true);
    pump();
    return list();
  }

  function setDir(dir) {
    fs.mkdirSync(dir, { recursive: true });
    const probe = path.join(dir, `.write-test-${Date.now()}`);
    fs.writeFileSync(probe, '');
    fs.unlinkSync(probe);
    data.dir = dir;
    // Downloads that haven't written anything yet go to the new place too.
    for (const it of data.items) {
      if (it.status !== 'completed' && !it.receivedBytes && !(active && active.item === it)) {
        it.filePath = uniquePath(targetPath({ ...it, ext: path.extname(it.filePath).slice(1) }));
      }
    }
    changed(true);
    return data.dir;
  }

  // The provider connection is wanted for playback: step aside.
  function pauseForPlayback() {
    playbackActive = true;
    clearTimeout(resumeTimer);
    if (concurrent) return;
    if (active) {
      console.log(`[downloads] pausing "${active.item.title}" while something plays`);
      stopActive('waiting');
      changed(true);
    }
  }

  // Playback has ended; pick up again once the connection is really free.
  function playbackEnded() {
    playbackActive = false;
    clearTimeout(resumeTimer);
    resumeTimer = setTimeout(() => pump(), 2500);
  }

  function pump() {
    if (active) return;
    if (!concurrent && playbackActive) return;
    if (!concurrent && hooks.isProviderBusy && hooks.isProviderBusy()) {
      clearTimeout(resumeTimer);
      resumeTimer = setTimeout(() => pump(), 4000);
      return;
    }
    const next = data.items.find((it) => it.status === 'waiting') || [...data.items].reverse().find((it) => it.status === 'queued');
    if (next) start(next);
  }

  function start(item) {
    item.status = 'downloading';
    item.error = '';
    let have = 0;
    try { have = fs.statSync(`${item.filePath}.part`).size; } catch {}
    item.receivedBytes = have;
    active = { item, req: null, file: null, retries: 0, windowBytes: 0, windowStart: Date.now(), retryTimer: null, release: null };
    active.release = hooks.acquire && !concurrent ? hooks.acquire(item.url, () => pauseForPlayback()) : null;
    ensureTicker();
    changed(true);
    request(active, item.url, 0);
  }

  function fail(a, message) {
    if (active !== a) return;
    console.log(`[downloads] "${a.item.title}" failed: ${message}`);
    stopActive('failed');
    a.item.error = message;
    changed(true);
    pump();
  }

  // req: the request that hit the problem. A dropped connection reports
  // itself more than once; only the first report counts.
  function retry(a, why, req) {
    if (active !== a) return;
    if (req && a.req !== req) return;
    try { if (a.req) a.req.destroy(); } catch {}
    try { if (a.file) a.file.end(); } catch {}
    a.req = null;
    a.file = null;
    a.retries++;
    if (a.retries > 10) { fail(a, why); return; }
    const delay = Math.min(15000, 1000 * 2 ** Math.min(4, a.retries - 1));
    console.log(`[downloads] "${a.item.title}": ${why} — retrying in ${delay}ms`);
    clearTimeout(a.retryTimer);
    a.retryTimer = setTimeout(() => {
      if (active !== a) return;
      try { a.item.receivedBytes = fs.statSync(`${a.item.filePath}.part`).size; } catch { a.item.receivedBytes = 0; }
      request(a, a.item.url, 0);
    }, delay);
  }

  function request(a, url, depth) {
    if (active !== a) return;
    if (depth > 6) { fail(a, 'Too many redirects'); return; }
    let u;
    try { u = new URL(url); } catch { fail(a, 'Invalid address'); return; }
    const item = a.item;
    const from = item.receivedBytes || 0;
    const lib = u.protocol === 'https:' ? https : http;
    const headers = { 'User-Agent': USER_AGENT, 'Accept-Encoding': 'identity' };
    if (from > 0) headers.Range = `bytes=${from}-`;

    const req = lib.get({
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      headers,
      timeout: 30000
    }, (res) => {
      if (active !== a || a.req !== req) { res.resume(); return; }
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        let next;
        try { next = new URL(res.headers.location, url).href; } catch { fail(a, 'Bad redirect'); return; }
        request(a, next, depth + 1);
        return;
      }
      if (res.statusCode === 416 && from > 0 && item.totalBytes && from >= item.totalBytes) {
        res.resume();
        finish(a);
        return;
      }
      if (res.statusCode !== 200 && res.statusCode !== 206) {
        res.resume();
        if (RETRYABLE_STATUS.has(res.statusCode)) retry(a, `HTTP ${res.statusCode}`, req);
        else fail(a, `Server answered HTTP ${res.statusCode}`);
        return;
      }

      const appending = res.statusCode === 206 && from > 0;
      if (res.statusCode === 206) {
        const m = /\/(\d+)\s*$/.exec(res.headers['content-range'] || '');
        if (m) item.totalBytes = parseInt(m[1], 10);
      } else {
        const len = parseInt(res.headers['content-length'], 10);
        if (len > 0) item.totalBytes = len;
      }
      if (!appending) item.receivedBytes = 0; // a server that ignores Range starts over

      // Enough room for the rest of it?
      if (item.totalBytes && typeof fs.statfsSync === 'function') {
        try {
          const st = fs.statfsSync(path.dirname(item.filePath));
          const free = Number(st.bavail) * Number(st.bsize);
          const needed = item.totalBytes - item.receivedBytes;
          if (free > 0 && needed > free) {
            res.resume();
            fail(a, `Not enough disk space (${(needed / 1073741824).toFixed(2)} GB needed)`);
            return;
          }
        } catch { /* can't tell — try anyway */ }
      }

      try { fs.mkdirSync(path.dirname(item.filePath), { recursive: true }); } catch {}
      const file = fs.createWriteStream(`${item.filePath}.part`, { flags: appending ? 'a' : 'w', highWaterMark: 8 * 1024 * 1024 });
      a.file = file;
      a.retries = 0;
      if (item.status !== 'downloading') { item.status = 'downloading'; changed(true); }

      res.on('data', (chunk) => {
        if (active !== a) return;
        item.receivedBytes += chunk.length;
        a.windowBytes += chunk.length;
      });
      res.pipe(file);
      file.on('error', (err) => fail(a, `Could not write the file: ${err.message}`));
      res.on('aborted', () => retry(a, 'connection dropped', req));
      res.on('error', (err) => retry(a, err.message, req));
      file.on('finish', () => {
        if (active !== a || a.file !== file) return;
        if (item.totalBytes && item.receivedBytes < item.totalBytes) retry(a, `connection ended at ${item.receivedBytes}/${item.totalBytes}`, req);
        else finish(a);
      });
    });
    a.req = req;
    req.setNoDelay(true);
    req.on('timeout', () => req.destroy(new Error('no data for 30 seconds')));
    req.on('error', (err) => retry(a, err.message, req));
  }

  function finish(a) {
    if (active !== a) return;
    const item = a.item;
    stopActive(null);
    try {
      const finalPath = fs.existsSync(item.filePath) ? uniquePath(item.filePath) : item.filePath;
      fs.renameSync(`${item.filePath}.part`, finalPath);
      item.filePath = finalPath;
      item.status = 'completed';
      item.completedAt = Date.now();
      if (!item.totalBytes) item.totalBytes = item.receivedBytes;
      console.log(`[downloads] completed "${item.title}" -> ${finalPath}`);
    } catch (err) {
      item.status = 'failed';
      item.error = `Could not finish the file: ${err.message}`;
    }
    changed(true);
    pump();
  }

  // Once a second: work out the speed and tell the window.
  function ensureTicker() {
    if (ticker) return;
    ticker = setInterval(() => {
      if (!active) {
        clearInterval(ticker);
        ticker = null;
        return;
      }
      const now = Date.now();
      const secs = Math.max(0.25, (now - active.windowStart) / 1000);
      const instant = active.windowBytes / secs;
      const prev = speeds.get(active.item.id);
      speeds.set(active.item.id, prev ? prev * 0.6 + instant * 0.4 : instant);
      active.windowBytes = 0;
      active.windowStart = now;
      changed(false);
    }, 1000);
  }

  // Whether downloads carry on while something is watched from the provider.
  function setConcurrent(on) {
    const next = !!on;
    if (next === concurrent) return;
    concurrent = next;
    console.log(`[downloads] download while watching: ${concurrent ? 'on' : 'off'}`);
    if (concurrent) {
      if (active && active.release) { try { active.release(); } catch {} active.release = null; }
      pump();
    } else if (active) {
      if (playbackActive) {
        stopActive('waiting');
        changed(true);
      } else if (hooks.acquire) {
        active.release = hooks.acquire(active.item.url, () => pauseForPlayback());
      }
    }
  }

  function isDownloadedFile(p) {
    const normal = path.resolve(p).toLowerCase();
    return data.items.some((it) => it.status === 'completed' && path.resolve(it.filePath).toLowerCase() === normal);
  }

  function shutdown() {
    if (active) stopActive('queued');
    saveNow();
  }

  // Start on whatever was left in line.
  setTimeout(() => pump(), 4000);

  return {
    list, add, pause, resume, remove, setDir,
    getDir: () => data.dir,
    get: (id) => { const it = find(id); return it ? view(it) : null; },
    pauseForPlayback, playbackEnded, setConcurrent, isDownloadedFile, shutdown
  };
}

module.exports = { createDownloadManager };
