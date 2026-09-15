// ===================== App State =====================
const state = {
  store: { accounts: [], activeAccountId: null, settings: {} },
  client: null,          // XtreamClient instance
  activeAccount: null,
  section: 'live',        // live | movies | series
  categories: [],
  categoryId: null,
  items: [],
  liveCats: null, movieCats: null, seriesCats: null,
  itemCache: {},          // "section:catId" -> array of items (avoids re-fetching)
  currentSeries: null,
  episodeContext: null,   // which episode list playback is walking through
  nowPlaying: null,
  filteredItems: [],
  renderedCount: 0,
  loadSeq: 0 // guards against a slow/stale category fetch landing after the user has already moved on
};

const PAGE_SIZE = 120;
// How long a full-catalog fetch from splash boot stays valid on disk before
// a relaunch has to redo it. Long enough that a quick "closed the app, came
// back a few minutes later" doesn't eat the full load again; short enough
// that a real content update on the provider's end still shows up soon.
const DATA_CACHE_TTL_MS = 10 * 60 * 1000;
let gridObserver = null;

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function showView(name) {
  $$('.view').forEach((v) => v.classList.remove('active'));
  $(`#view-${name}`).classList.add('active');
}

// ===================== Persistence =====================
async function loadStore() {
  state.store = await window.api.storeGet();
}
async function saveStore() {
  await window.api.storeSet(state.store);
}

// ===================== Watch history (Continue Watching / Recently Watched) =====================
const HISTORY_LIMIT = 60;

function historyList() {
  if (!state.store.history) state.store.history = [];
  return state.store.history;
}

function historyKey(meta) {
  return meta.historyKey || meta.url;
}

function findHistoryEntry(meta) {
  return historyList().find((h) => h.key === historyKey(meta));
}

// Called frequently (throttled) while playing, and once when playback stops.
function upsertHistory(meta, { resumeAt = 0, duration = 0 } = {}) {
  const list = historyList();
  const key = historyKey(meta);
  const idx = list.findIndex((h) => h.key === key);
  const entry = {
    key,
    type: meta.type,
    title: meta.title,
    subtitle: meta.subtitle,
    thumb: meta.thumb,
    url: meta.url,
    isLive: !!meta.isLive,
    resumeAt: meta.isLive ? 0 : resumeAt,
    duration: meta.isLive ? 0 : duration,
    replay: meta.replay || null, // enough info to recreate playback (e.g. series episode context)
    updatedAt: Date.now()
  };
  if (idx >= 0) list.splice(idx, 1);
  list.unshift(entry);
  if (list.length > HISTORY_LIMIT) list.length = HISTORY_LIMIT;
  updateHistoryBadges();
  saveStore(); // fire and forget — don't block playback UI on disk writes
}

function updateHistoryBadges() {
  const list = historyList();
  const continuing = list.filter((h) => !h.isLive && h.duration > 0 && h.resumeAt > 5 && h.resumeAt < h.duration * 0.95);
  const cw = document.getElementById('cw-count');
  const rc = document.getElementById('recent-count');
  if (cw) cw.textContent = continuing.length;
  if (rc) rc.textContent = list.length;
}

// ===================== Login =====================
function initLoginTabs() {
  $$('.ltab').forEach((btn) => {
    btn.addEventListener('click', () => {
      $$('.ltab').forEach((b) => b.classList.remove('active'));
      $$('.ltab-panel').forEach((p) => p.classList.remove('active'));
      btn.classList.add('active');
      $(`#tab-${btn.dataset.tab}`).classList.add('active');
    });
  });
}

function renderSavedAccounts() {
  const box = $('#saved-accounts');
  box.innerHTML = '';
  if (!state.store.accounts.length) return;
  state.store.accounts.forEach((acc) => {
    const row = document.createElement('div');
    row.className = 'saved-account-row';
    row.innerHTML = `
      <span class="sa-name">${escapeHtml(acc.name)}</span>
      <span class="sa-actions">
        <button data-act="use" title="Login">▶</button>
        <button data-act="del" title="Remove">✕</button>
      </span>`;
    row.querySelector('[data-act="use"]').addEventListener('click', () => loginWithAccount(acc));
    row.querySelector('[data-act="del"]').addEventListener('click', async () => {
      state.store.accounts = state.store.accounts.filter((a) => a.id !== acc.id);
      await saveStore();
      renderSavedAccounts();
    });
    box.appendChild(row);
  });
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

async function loginWithAccount(acc) {
  const errBox = $('#login-error');
  errBox.textContent = '';
  const btn = $('#btn-login');
  btn.disabled = true;
  btn.textContent = 'Connecting...';
  try {
    if (acc.type === 'xtream') {
      const client = new XtreamClient(acc.url, acc.username, acc.password);
      const auth = await client.authenticate();
      state.client = client;
      state.activeAccount = acc;
      state.store.activeAccountId = acc.id;
      await saveStore();
      enterApp(auth);
    } else if (acc.type === 'm3u') {
      const items = await parseM3U(acc.url);
      state.client = null;
      state.activeAccount = acc;
      state.m3uItems = items;
      state.store.activeAccountId = acc.id;
      await saveStore();
      enterAppM3U();
    }
  } catch (err) {
    errBox.textContent = err.message || 'Login failed';
  } finally {
    btn.disabled = false;
    btn.textContent = 'Login';
  }
}

function initLoginForm() {
  $('#btn-login').addEventListener('click', async () => {
    const activeTab = $('.ltab.active').dataset.tab;
    if (activeTab === 'xtream') {
      let url = $('#x-url').value.trim();
      const user = $('#x-user').value.trim();
      const pass = $('#x-pass').value.trim();
      if (!url || !user || !pass) {
        $('#login-error').textContent = 'Please fill in server URL, username and password.';
        return;
      }
      if (!/^https?:\/\//i.test(url)) url = 'http://' + url;
      const acc = { id: 'x_' + Date.now(), type: 'xtream', name: `${user} @ ${new URL(url).hostname}`, url, username: user, password: pass };
      const existing = state.store.accounts.find((a) => a.type === 'xtream' && a.url === url && a.username === user);
      if (!existing) { state.store.accounts.unshift(acc); await saveStore(); }
      await loginWithAccount(existing || acc);
    } else {
      const name = $('#m-name').value.trim() || 'My Playlist';
      const url = $('#m-url').value.trim();
      if (!url) { $('#login-error').textContent = 'Please provide an M3U URL.'; return; }
      const acc = { id: 'm_' + Date.now(), type: 'm3u', name, url };
      const existing = state.store.accounts.find((a) => a.type === 'm3u' && a.url === url);
      if (!existing) { state.store.accounts.unshift(acc); await saveStore(); }
      await loginWithAccount(existing || acc);
    }
  });
}

// ===================== Enter App =====================
function enterApp(auth) {
  // How many streams the provider lets this account run at once decides
  // whether a download can keep going while something is watched.
  state.maxConnections = parseInt(auth && auth.user_info && auth.user_info.max_connections, 10) || 1;
  applyDownloadPolicy();
  showView('app');
  $('#account-name').textContent = state.activeAccount.username;
  const exp = auth.user_info.exp_date;
  $('#account-sub').textContent = exp && exp !== null ? `Expires: ${new Date(exp * 1000).toLocaleDateString()}` : 'Xtream Codes';
  switchSection(settings().startSection);
  maybeShowLanguagePicker();
}

function enterAppM3U() {
  state.maxConnections = 1; // an M3U list doesn't say; assume the usual single connection
  applyDownloadPolicy();
  showView('app');
  $('#account-name').textContent = state.activeAccount.name;
  $('#account-sub').textContent = 'M3U Playlist';
  switchSection(settings().startSection);
  maybeShowLanguagePicker();
}

// Shown once, the first time the app is ever entered (tracked by
// languagePicked in the store) — after that, language only changes from
// Settings > Language. Built dynamically like the announcement modal so no
// extra static HTML is needed.
function maybeShowLanguagePicker() {
  if (state.store.settings && state.store.settings.languagePicked) return;
  if (document.getElementById('app-language-picker')) return;
  const overlay = document.createElement('div');
  overlay.id = 'app-language-picker';
  overlay.className = 'app-modal-overlay';
  overlay.innerHTML = `
    <div class="app-modal-card">
      <div class="app-modal-title">Choose your language</div>
      <div class="lang-picker-list">
        ${LANGUAGES.map((l) => `<button class="btn-secondary lang-picker-btn" data-lang="${l.code}">${l.name}</button>`).join('')}
      </div>
    </div>`;
  document.body.appendChild(overlay);
  overlay.querySelectorAll('.lang-picker-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      await setSetting('language', btn.dataset.lang);
      state.store.settings.languagePicked = true;
      await saveStore();
      overlay.remove();
    });
  });
}

// ===================== Playlist switcher =====================
function initPlaylistSwitcher() {
  const menu = $('#playlist-menu');
  const pill = $('#playlist-pill');

  const close = () => { menu.hidden = true; };
  pill.addEventListener('click', (e) => {
    e.stopPropagation();
    if (menu.hidden) { renderPlaylistMenu(); menu.hidden = false; } else close();
  });
  document.addEventListener('click', (e) => {
    if (!menu.hidden && !menu.contains(e.target)) close();
  });
  $('#pl-menu-add').addEventListener('click', () => { close(); openSettings('playlists'); });
}

function renderPlaylistMenu() {
  const list = $('#pl-menu-list');
  const accounts = state.store.accounts || [];
  $('#pl-menu-head').textContent = `YOUR PLAYLISTS (${accounts.length})`;
  list.innerHTML = '';

  accounts.forEach((acc) => {
    const isActive = state.activeAccount && acc.id === state.activeAccount.id;
    const row = document.createElement('button');
    row.className = 'pl-row' + (isActive ? ' active' : '');
    row.innerHTML = `
      <span class="pl-icon">${acc.type === 'xtream' ? '☰' : '🔗'}</span>
      <span class="pl-row-name">${escapeHtml(acc.name)}
        <span class="pl-row-sub">${acc.type === 'xtream' ? 'Xtream Codes' : 'M3U playlist'}</span>
      </span>
      ${isActive ? '<span class="pl-row-check">✓</span>' : ''}`;
    row.addEventListener('click', () => {
      $('#playlist-menu').hidden = true;
      if (!isActive) switchPlaylist(acc);
    });
    list.appendChild(row);
  });

  if (!accounts.length) {
    list.innerHTML = '<div style="padding:10px 8px;color:var(--text-dim);font-size:12px;">No playlists yet.</div>';
  }
}

// Switching source means everything cached for the old one is wrong, so the
// catalog, item cache and any playback are dropped before reconnecting.
async function switchPlaylist(acc) {
  $('#account-name').textContent = 'Switching...';
  if (player) { stopHistoryTracking(); player.destroy(); }
  state.client = null;
  state.m3uItems = null;
  state.liveCats = state.movieCats = state.seriesCats = null;
  state.itemCache = {};
  state.items = [];
  state.categories = [];
  window.api.setCatalog(null).catch(() => {});

  try {
    if (acc.type === 'xtream') {
      const client = new XtreamClient(acc.url, acc.username, acc.password);
      const auth = await client.authenticate();
      state.client = client;
      state.activeAccount = acc;
      state.store.activeAccountId = acc.id;
      await saveStore();
      enterApp(auth);
    } else {
      const items = await parseM3U(acc.url);
      state.activeAccount = acc;
      state.m3uItems = items;
      state.store.activeAccountId = acc.id;
      await saveStore();
      enterAppM3U();
    }
  } catch (err) {
    $('#account-name').textContent = acc.name;
    $('#account-sub').textContent = 'Could not connect';
    alert(`Could not switch to "${acc.name}": ${err.message || 'connection failed'}`);
  }
}

// ===================== Sections / Categories =====================
async function switchSection(section) {
  state.viewingDownloads = false;
  state.section = section;
  state.categoryId = null;
  $$('.tb-tab').forEach((t) => t.classList.toggle('active', t.dataset.section === section));
  $$('.sb-quick').forEach((el) => el.classList.remove('active'));
  $('#content-title').textContent = section === 'live' ? 'All channels' : section === 'movies' ? 'All movies' : 'All series';
  $('#item-search').value = '';

  // Live TV gets its own inline-preview + channel-list layout instead of
  // the movie/series poster grid.
  $('#item-grid').style.display = section === 'live' ? 'none' : '';
  $('#live-panel').classList.toggle('active', section === 'live');
  if (section !== 'live') stopLivePreview();

  // Same stale-response race as loadItemsForCategory: if the user switches
  // sections again before this resolves, don't let the old section's
  // categories land on top of the new one.
  const mySeq = ++state.loadSeq;

  setGridLoading();
  try {
    await loadCategoriesForSection();
  } catch (err) {
    if (mySeq !== state.loadSeq) return;
    renderCategoryError(err);
    return;
  }
  if (mySeq !== state.loadSeq) return;
  renderCategories();
  await loadItemsForCategory(null);
}

async function loadCategoriesForSection() {
  if (!state.client) {
    // M3U mode: derive categories from groups
    const groups = {};
    (state.m3uItems || []).forEach((it) => { groups[it.group] = (groups[it.group] || 0) + 1; });
    state.categories = Object.keys(groups).sort().map((g) => ({ category_id: g, category_name: g, count: groups[g] }));
    return;
  }
  if (state.section === 'live') {
    if (!state.liveCats) state.liveCats = await state.client.getLiveCategories();
    state.categories = state.liveCats;
  } else if (state.section === 'movies') {
    if (!state.movieCats) state.movieCats = await state.client.getVodCategories();
    state.categories = state.movieCats;
  } else {
    if (!state.seriesCats) state.seriesCats = await state.client.getSeriesCategories();
    state.categories = state.seriesCats;
  }
  state.categories = withoutAdult(state.categories, (c) => c.category_name);
}

// "18+" needs its own pattern: there's no word boundary after a plus sign,
// so inside \b(...)\b it never matched anything.
const ADULT_WORDS = /\b(xxx|adults?|porno?|sexy?|erotica?|playboy|hustler|brazzers|hot\s*tv)\b|18\s*\+|\+\s*18\b/i;
// Applied to both the category list and the items inside "All", so turning
// the switch on actually removes the content rather than just hiding a menu.
function withoutAdult(list, nameOf) {
  if (!settings().adultFilter) return list;
  return (list || []).filter((x) => !ADULT_WORDS.test(nameOf(x) || ''));
}

function renderCategoryError(err) {
  $('#cat-list').innerHTML = '';
  $('#item-grid').innerHTML = `
    <div class="error-state">
      <div class="err-icon">⚠️</div>
      <div class="err-msg">Could not load data</div>
      <div>${escapeHtml(err.message || 'Please check your connection and try again.')}</div>
      <button class="btn-retry" id="btn-retry-section">Retry</button>
    </div>`;
  $('#btn-retry-section').addEventListener('click', () => switchSection(state.section));
}

function renderCategories() {
  const list = $('#cat-list');
  $('#cat-count').textContent = state.categories.length;
  const q = ($('#cat-search').value || '').toLowerCase();
  list.innerHTML = '';

  const allRow = document.createElement('div');
  allRow.className = 'cat-item' + (state.categoryId === null ? ' active' : '');
  allRow.innerHTML = `<span>All ${state.section}</span>`;
  allRow.addEventListener('click', () => selectCategory(null));
  list.appendChild(allRow);

  state.categories
    .filter((c) => c.category_name.toLowerCase().includes(q))
    .forEach((c) => {
      const row = document.createElement('div');
      row.className = 'cat-item' + (state.categoryId === c.category_id ? ' active' : '');
      row.innerHTML = `<span>${escapeHtml(c.category_name)}</span>`;
      row.addEventListener('click', () => selectCategory(c.category_id));
      list.appendChild(row);
    });
}

async function selectCategory(catId) {
  state.categoryId = catId;
  renderCategories();
  await loadItemsForCategory(catId);
}

function setGridLoading() {
  $('#item-grid').innerHTML = '<div class="loading-state"><div class="spinner"></div><div>Loading...</div></div>';
  $('#content-sub').textContent = '';
}

function cacheKey(catId) {
  return `${state.section}:${catId || 'all'}`;
}

// Swaps the content area back to the poster grid, undoing the Live TV
// layout (inline preview + channel list) if that is what's showing.
function showItemGrid() {
  state.viewingDownloads = false;
  $('#item-grid').style.display = '';
  $('#live-panel').classList.remove('active');
  stopLivePreview();
}

// Routes artwork through the local proxy, which downscales it to grid size
// once and keeps it on disk. Providers serve full-resolution posters, and a
// screen full of those is what made the grids take so long to fill in.
//
// Requests are spread over several local ports: the browser runs only six at
// a time per port, which is what made a full screen of posters trickle in.
// The same artwork always maps to the same port so its cached copy is hit.
function thumbUrl(url, w = 300) {
  const bases = state.thumbBases && state.thumbBases.length ? state.thumbBases : (state.thumbBase ? [state.thumbBase] : []);
  if (!url || !bases.length || !/^https?:\/\//i.test(url)) return url || '';
  let h = 0;
  for (let i = 0; i < url.length; i++) h = (h * 31 + url.charCodeAt(i)) | 0;
  const base = bases[Math.abs(h) % bases.length];
  return `${base}/thumb?w=${w}&url=${encodeURIComponent(url)}`;
}

// Real movies/episodes almost always carry a year somewhere (in the name,
// or a release_date/added field); odd one-off clips that got miscategorized
// into a VOD/series category (a wrestling show recording, a single sports
// clip, etc.) usually don't. Sorting real dated content to the top and
// undated stragglers to the bottom is purely a display-order change — it
// never touches what gets fetched, cached, or how any other section works.
function extractYear(item, section) {
  const name = item.name || item.title || '';
  const m = /(19|20)\d{2}/.exec(name);
  if (m) return parseInt(m[0], 10);
  if (section === 'series' && item.release_date) {
    const y = parseInt(String(item.release_date).slice(0, 4), 10);
    if (y > 1900 && y < 2100) return y;
  }
  if (section === 'movies' && item.added) {
    // "added" is when the provider added it to the catalog, not its release
    // year — only used as a last-resort recency signal when the name itself
    // has no year, never shown to the user.
    const d = new Date(parseInt(item.added, 10) * 1000);
    if (!isNaN(d.getTime())) return d.getFullYear();
  }
  return null;
}

function sortByRecency(items, section) {
  return items
    .map((it, i) => ({ it, i, year: extractYear(it, section) }))
    .sort((a, b) => {
      if (a.year === null && b.year === null) return a.i - b.i; // keep original relative order
      if (a.year === null) return 1;  // no detectable year -> sink to the bottom
      if (b.year === null) return -1;
      if (b.year !== a.year) return b.year - a.year; // newest first
      return a.i - b.i;
    })
    .map((x) => x.it);
}

async function loadItemsForCategory(catId) {
  state.viewingDownloads = false;
  const key = cacheKey(catId);
  const section = state.section; // frozen for this call — see the race-guard note below

  // Guards against a real bug that was showing Live channels / Movies while
  // browsing Series: if the user switches section/category again before an
  // earlier fetch resolves, that OLD (now-stale) response would still land
  // and overwrite state.items with the WRONG content type. Bumping this on
  // every call — cache-hit or not — means only the most recently started
  // load is ever allowed to apply its result.
  const mySeq = ++state.loadSeq;

  // Serve from cache instantly (feels instant, no spinner flash). An empty
  // cached list is not trusted: that is what a failed download looks like,
  // and trusting it is how Series ended up showing "0 items" until restart.
  if (state.itemCache[key] && state.itemCache[key].length) {
    state.items = state.itemCache[key];
    renderGrid();
    return;
  }

  setGridLoading();
  // #item-grid (where setGridLoading writes) is hidden while browsing Live
  // TV — without this, picking a new category left the OLD channel list
  // sitting there with no sign anything was happening until the fetch
  // finished, which read as "categories don't work".
  if (section === 'live') {
    const list = $('#live-list');
    if (list) list.innerHTML = '<div class="loading-state"><div class="spinner"></div><div>Loading...</div></div>';
  }
  try {
    let items;
    if (!state.client) {
      items = state.m3uItems || [];
      if (catId) items = items.filter((it) => it.group === catId);
    } else if (section === 'live') {
      items = await state.client.getLiveStreams(catId);
    } else if (section === 'movies') {
      items = await state.client.getVodStreams(catId);
    } else {
      items = await state.client.getSeries(catId);
    }
    if (mySeq !== state.loadSeq) return; // a newer load superseded this one — discard
    items = withoutAdult(items, (it) => it.name || it.title);
    if (section === 'movies' || section === 'series') items = sortByRecency(items, section);
    state.itemCache[key] = items;
    state.items = items;
    renderGrid();
  } catch (err) {
    if (mySeq !== state.loadSeq) return;
    $('#item-grid').innerHTML = `
      <div class="error-state">
        <div class="err-icon">⚠️</div>
        <div class="err-msg">Could not load ${escapeHtml(section)}</div>
        <div>${escapeHtml(err.message || 'Please check your connection and try again.')}</div>
        <button class="btn-retry" id="btn-retry-items">Retry</button>
      </div>`;
    $('#btn-retry-items').addEventListener('click', () => {
      delete state.itemCache[key];
      loadItemsForCategory(catId);
    });
  }
}

// Instant client-side search across the already-loaded list, with windowed
// (paginated) DOM rendering so huge lists (tens of thousands of items) never
// block or slow down the UI.
function renderGrid() {
  state.viewingDownloads = false;
  if (state.section === 'live') {
    renderLiveList();
    return;
  }

  const q = ($('#item-search').value || '').trim().toLowerCase();
  let items = state.items;
  if (q) {
    items = items.filter((it) => (it.name || it.title || '').toLowerCase().includes(q));
  }
  state.filteredItems = items;
  state.renderedCount = 0;

  $('#content-sub').textContent = `${items.length} items`;

  const grid = $('#item-grid');
  cancelPostersIn(grid);
  grid.innerHTML = '';
  $('.content').scrollTop = 0;

  if (!items.length) {
    grid.innerHTML = '<div class="empty-state">No items found.</div>';
    return;
  }

  appendGridBatch();
}

function appendGridBatch() {
  const grid = $('#item-grid');
  const items = state.filteredItems;
  const start = state.renderedCount;
  const end = Math.min(items.length, start + PAGE_SIZE);
  if (start === 0) {
    // remove any previous sentinel before first batch
  }

  const frag = document.createDocumentFragment();
  for (let i = start; i < end; i++) frag.appendChild(renderCard(items[i]));

  const sentinel = document.getElementById('grid-sentinel');
  if (sentinel) sentinel.remove();
  grid.appendChild(frag);
  observePosters(grid);
  state.renderedCount = end;

  if (end < items.length) {
    const s = document.createElement('div');
    s.id = 'grid-sentinel';
    s.className = 'load-more-row';
    s.innerHTML = '<button class="btn-loadmore">Load more</button>';
    s.querySelector('button').addEventListener('click', appendGridBatch);
    grid.appendChild(s);
    observeSentinel(s);
  }
}

// Loads artwork only for what is actually on screen (plus a small margin).
//
// Two things made long lists like "All movies" stay blank while scrolling:
// every card that flew past on its way down started a download and never
// gave it back, so the handful of connections the browser allows were busy
// with hundreds of posters nobody was looking at any more, and the ones on
// screen waited at the back of that queue. Now a card has to stay in view
// for a moment before its poster is requested, and a download still running
// when its card leaves the screen is cancelled.
const POSTER_DWELL_MS = 120;
const posterObservers = new Map(); // scroll container -> IntersectionObserver
const posterTimers = new WeakMap();  // element -> pending dwell timer
const postersInFlight = new Set();   // elements whose artwork is downloading

function startPoster(el) {
  if (el.dataset.src) {
    const url = el.dataset.src;
    el.onload = () => {
      postersInFlight.delete(el);
      delete el.dataset.src;
      const io = el._posterObserver;
      if (io) io.unobserve(el);
    };
    el.onerror = () => {
      postersInFlight.delete(el);
      delete el.dataset.src;
      const io = el._posterObserver;
      if (io) io.unobserve(el);
      // Broken artwork: show the title placeholder instead of a broken image.
      const thumb = el.closest('.card-thumb');
      const card = el.closest('.card');
      el.remove();
      if (thumb && card && !thumb.querySelector('.card-thumb-name')) {
        const name = document.createElement('span');
        name.className = 'card-thumb-name';
        name.textContent = (card.querySelector('.card-title') || {}).textContent || '';
        thumb.insertBefore(name, thumb.firstChild);
      }
    };
    postersInFlight.add(el);
    el.src = url;
  } else if (el.dataset.bg) {
    // A CSS background can't be cancelled once requested, so it is fetched
    // through an Image first (which can be) and applied when it arrives.
    const url = el.dataset.bg;
    const img = new Image();
    img.decoding = 'async';
    el._posterImg = img;
    const finish = (ok) => {
      postersInFlight.delete(el);
      el._posterImg = null;
      delete el.dataset.bg;
      if (ok) el.style.backgroundImage = `url('${url}')`;
      const io = el._posterObserver;
      if (io) io.unobserve(el);
    };
    img.onload = () => finish(true);
    img.onerror = () => finish(false);
    postersInFlight.add(el);
    img.src = url;
  }
}

function cancelPoster(el) {
  const timer = posterTimers.get(el);
  if (timer) { clearTimeout(timer); posterTimers.delete(el); }
  if (!postersInFlight.has(el)) return;
  postersInFlight.delete(el);
  if (el.dataset.src) {
    el.onload = el.onerror = null;
    el.removeAttribute('src'); // drops the request; data-src stays for later
  } else if (el._posterImg) {
    el._posterImg.onload = el._posterImg.onerror = null;
    el._posterImg.src = '';
    el._posterImg = null;
  }
}

function posterObserverFor(scrollRoot) {
  let io = posterObservers.get(scrollRoot);
  if (io) return io;
  io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      const el = entry.target;
      if (entry.isIntersecting) {
        if (postersInFlight.has(el) || posterTimers.has(el)) return;
        posterTimers.set(el, setTimeout(() => {
          posterTimers.delete(el);
          if (el.isConnected) startPoster(el);
        }, POSTER_DWELL_MS));
      } else {
        cancelPoster(el);
      }
    });
  }, { root: scrollRoot, rootMargin: '150px 0px' });
  posterObservers.set(scrollRoot, io);
  return io;
}

// Watches every not-yet-loaded poster under `root`. scrollRoot is the
// element that actually scrolls those posters (the main content area unless
// told otherwise, e.g. the live channel list scrolls on its own).
function observePosters(root, scrollRoot) {
  const scroller = scrollRoot || $('.content');
  const io = posterObserverFor(scroller);
  root.querySelectorAll('img[data-src], [data-bg]').forEach((el) => {
    if (el._posterObserver === io) return;
    el._posterObserver = io;
    io.observe(el);
  });
}

// Before a list is thrown away and redrawn: cancel its downloads now rather
// than waiting for the observer to notice the elements are gone.
function cancelPostersIn(root) {
  for (const el of [...postersInFlight]) {
    if (root.contains(el)) {
      cancelPoster(el);
      if (el._posterObserver) el._posterObserver.unobserve(el);
    }
  }
}

function observeSentinel(el) {
  if (!gridObserver) {
    gridObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) appendGridBatch();
      });
    }, { root: $('.content'), rootMargin: '400px' });
  }
  gridObserver.observe(el);
}

// A large share of this catalog (close to 30,000 movies) links artwork as a
// bare TMDB size folder — ".../t/p/w600_and_h900_bestv2" with no image in
// it. Those can only ever fail, so they show the title card straight away
// instead of spending a request each.
function usableArtwork(url) {
  if (!url || typeof url !== 'string') return '';
  const path = url.split(/[?#]/)[0].replace(/\/+$/, '');
  const last = path.slice(path.lastIndexOf('/') + 1);
  if (/\/t\/p$/i.test(path.slice(0, path.lastIndexOf('/'))) && /^(w\d+|h\d+|original)(_and_h\d+)?(_bestv2)?$/i.test(last)) return '';
  if (/^https?:\/\/[^/]+$/i.test(path)) return '';
  return url;
}

function renderCard(it, sectionOverride) {
  const section = sectionOverride || state.section;
  const card = document.createElement('div');
  const isChannel = section === 'live';
  card.className = 'card' + (isChannel ? ' channel' : '');

  const name = it.name || it.title || 'Unknown';
  const img = usableArtwork(it.stream_icon || it.cover || it.logo || '');
  const rating = it.rating_5based ? (it.rating_5based * 2).toFixed(1) : (it.rating ? Number(it.rating).toFixed(1) : null);
  const faved = isFavorite(section, it);

  // The poster URL is parked in data-src and only becomes a real request
  // once the card is near the viewport (see observePosters). The browser's
  // own lazy loading reaches much further ahead than that, which on a
  // 69,000-item catalog means fetching artwork nobody is looking at.
  card.innerHTML = `
    <div class="card-thumb">${img ? `<img data-src="${thumbUrl(img)}" decoding="async" alt="" />` : escapeHtml(name)}
      ${rating ? `<span class="card-rating">★ ${rating}</span>` : ''}
      <button class="card-fav${faved ? ' active' : ''}" title="Favorite">${faved ? '♥' : '♡'}</button>
    </div>
    <div class="card-title">${escapeHtml(name)}</div>
  `;

  card.querySelector('.card-fav').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleFavorite(section, it);
    const btn = e.currentTarget;
    const nowFaved = isFavorite(section, it);
    btn.classList.toggle('active', nowFaved);
    btn.textContent = nowFaved ? '♥' : '♡';
  });

  card.addEventListener('click', () => {
    if (section === 'live') {
      playLive(it);
    } else if (section === 'movies') {
      playMovie(it);
    } else {
      openSeries(it);
    }
  });

  return card;
}

// ===================== Favorites =====================
function favoritesList() {
  if (!state.store.favorites) state.store.favorites = [];
  return state.store.favorites;
}

function favKey(section, it) {
  return `${section}:${it.stream_id || it.series_id || it.name}`;
}

function isFavorite(section, it) {
  return favoritesList().some((f) => f.key === favKey(section, it));
}

function toggleFavorite(section, it) {
  const list = favoritesList();
  const key = favKey(section, it);
  const idx = list.findIndex((f) => f.key === key);
  if (idx >= 0) {
    list.splice(idx, 1);
  } else {
    list.unshift({ key, section, item: it, addedAt: Date.now() });
    if (list.length > 300) list.length = 300;
  }
  updateFavCount();
  saveStore();
}

function updateFavCount() {
  const el = document.getElementById('fav-count');
  if (el) el.textContent = favoritesList().length;
}

function showFavoritesView() {
  $$('.sb-quick').forEach((el) => el.classList.remove('active'));
  document.getElementById('sb-favorites').classList.add('active');
  $$('.tb-tab').forEach((t) => t.classList.remove('active'));
  $('#cat-list').innerHTML = '';
  $('#item-search').value = '';
  showItemGrid();

  const list = favoritesList();
  $('#content-title').textContent = 'Favorites';
  $('#content-sub').textContent = `${list.length} items`;

  const grid = $('#item-grid');
  cancelPostersIn(grid);
  grid.innerHTML = '';
  if (!list.length) {
    grid.innerHTML = '<div class="empty-state">No favorites yet — tap the ♡ on any channel, movie or series.</div>';
    return;
  }

  list.forEach((f) => grid.appendChild(renderCard(f.item, f.section)));
  observePosters(grid);
}

// ===================== Search wiring =====================
function initSearchBoxes() {
  $('#cat-search').addEventListener('input', renderCategories);
  $('#item-search').addEventListener('input', renderGrid);
}

function initTabBar() {
  $$('.tb-tab').forEach((tab) => tab.addEventListener('click', () => switchSection(tab.dataset.section)));
}

// ===================== Continue Watching / Recently Watched views =====================
function initQuickLists() {
  $('#sb-continue').addEventListener('click', () => showHistoryView('continue'));
  $('#sb-recent').addEventListener('click', () => showHistoryView('recent'));
  $('#sb-favorites').addEventListener('click', () => showFavoritesView());
}

function showHistoryView(kind) {
  $$('.sb-quick').forEach((el) => el.classList.remove('active'));
  document.getElementById(kind === 'continue' ? 'sb-continue' : 'sb-recent').classList.add('active');
  $$('.tb-tab').forEach((t) => t.classList.remove('active'));
  $('#cat-list').innerHTML = '';
  $('#item-search').value = '';
  // Coming from Live TV, its inline preview and channel list own the content
  // area — without this the history title appears above the live channel list.
  showItemGrid();

  const list = historyList();
  const items = kind === 'continue'
    ? list.filter((h) => !h.isLive && h.duration > 0 && h.resumeAt > 5 && h.resumeAt < h.duration * 0.95)
    : list;

  $('#content-title').textContent = kind === 'continue' ? 'Continue Watching' : 'Recently Watched';
  $('#content-sub').textContent = `${items.length} items`;

  const grid = $('#item-grid');
  cancelPostersIn(grid);
  grid.innerHTML = '';
  if (!items.length) {
    grid.innerHTML = `<div class="empty-state">${kind === 'continue' ? 'Nothing in progress yet.' : 'Nothing watched yet.'}</div>`;
    return;
  }

  items.forEach((h) => {
    const card = document.createElement('div');
    card.className = 'card' + (h.type === 'live' ? ' channel' : '');
    const pct = h.duration > 0 ? Math.min(100, (h.resumeAt / h.duration) * 100) : 0;
    card.innerHTML = `
      <div class="card-thumb"${h.thumb ? ` data-bg="${thumbUrl(h.thumb)}"` : ''}>${h.thumb ? '' : escapeHtml(h.title)}</div>
      <div class="card-title">${escapeHtml(h.title)}</div>
      ${pct > 0 ? `<div class="card-progress"><div class="card-progress-fill" style="width:${pct.toFixed(0)}%"></div></div>` : ''}
    `;
    card.addEventListener('click', () => {
      state.episodeContext = null;
      openPlayer({
        url: h.url, isLive: h.isLive, title: h.title, subtitle: h.subtitle, thumb: h.thumb,
        type: h.type, historyKey: h.key, replay: h.replay, resumeAt: h.resumeAt
      });
    });
    grid.appendChild(card);
  });
  observePosters(grid);
}

function updateClock() {
  const now = new Date();
  const fmt = settings().timeFormat;
  const opts = { hour: '2-digit', minute: '2-digit' };
  if (fmt === '12') opts.hour12 = true;
  if (fmt === '24') opts.hour12 = false;
  $('#clock-time').textContent = now.toLocaleTimeString([], opts);
  $('#clock-date').textContent = now.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
}

function initClock() {
  updateClock();
  setInterval(updateClock, 30000);
}

function initLogout() {
  $('#btn-logout').addEventListener('click', () => {
    if (player) player.destroy();
    state.client = null;
    state.activeAccount = null;
    state.liveCats = state.movieCats = state.seriesCats = null;
    state.itemCache = {};
    showView('login');
    renderSavedAccounts();
  });
}

// ===================== Settings =====================
// Every control here is backed by state.store and read by the code that
// actually does the work — nothing in this panel is decorative.
const SETTINGS_DEFAULTS = {
  quality: 'auto',
  timeFormat: 'system',   // system | 12 | 24
  startSection: 'live',   // live | movies | series
  resume: true,
  autoNextEpisode: true,
  seekStep: 10,
  theme: 'dark',          // dark | midnight | light
  posterSize: 'normal',   // small | normal | large
  adultFilter: false,
  downloadWhileWatching: 'on', // on | off
  audioLang: '',          // last audio language picked in the player
  subtitleLang: '',       // last subtitle language picked ('' = off)
  language: 'en'          // app UI language — see src/i18n.js
};

function settings() {
  if (!state.store.settings) state.store.settings = {};
  return Object.assign({}, SETTINGS_DEFAULTS, state.store.settings);
}

async function setSetting(key, value) {
  state.store.settings = state.store.settings || {};
  state.store.settings[key] = value;
  await saveStore();
  applySettings();
}

// Pushes the stored preferences into the parts of the app that use them.
function applySettings() {
  const s = settings();
  document.documentElement.setAttribute('data-theme', s.theme);
  document.documentElement.setAttribute('data-poster', s.posterSize);
  if (player) player.setQuality(s.quality);
  updateClock();
  applyLanguage(s.language);
}

function initSettings() {
  $('#btn-settings').addEventListener('click', () => openSettings('playlists'));
}

// label/blurb are i18n keys, not display text — resolved via t() at render
// time (inside openSettings) so a language switch after this array was
// built still shows correctly, rather than baking in whatever the language
// was when the module first loaded.
const SETTINGS_SECTIONS = [
  { id: 'playlists', label: 'settings.nav.playlists', icon: '☰', blurb: 'settings.nav.playlists.blurb' },
  { id: 'language', label: 'settings.nav.language', icon: '🌐', blurb: 'settings.nav.language.blurb' },
  { id: 'general', label: 'settings.nav.general', icon: '⚙', blurb: 'settings.nav.general.blurb' },
  { id: 'downloads', label: 'settings.nav.downloads', icon: '⬇', blurb: 'settings.nav.downloads.blurb' },
  { id: 'appearance', label: 'settings.nav.appearance', icon: '🎨', blurb: 'settings.nav.appearance.blurb' },
  { id: 'backup', label: 'settings.nav.backup', icon: '↥', blurb: 'settings.nav.backup.blurb' },
  { id: 'troubleshooting', label: 'settings.nav.troubleshooting', icon: '🛟', blurb: 'settings.nav.troubleshooting.blurb' },
  { id: 'about', label: 'settings.nav.about', icon: 'ⓘ', blurb: 'settings.nav.about.blurb' },
  { id: 'updates', label: 'settings.nav.updates', icon: '🔄', blurb: 'settings.nav.updates.blurb' }
];

function openSettings(sectionId = 'playlists') {
  let overlay = document.getElementById('settings-modal');
  if (!overlay) {
    overlay = document.createElement('div');
    overlay.id = 'settings-modal';
    overlay.className = 'settings-overlay';
    overlay.innerHTML = `
      <div class="settings-dialog">
        <div class="settings-head">
          <div>
            <h3 id="settings-title">${t('settings.title')}</h3>
            <div class="settings-blurb" id="settings-blurb"></div>
          </div>
          <button id="settings-close" class="icon-btn">✕</button>
        </div>
        <div class="settings-body">
          <nav class="settings-nav" id="settings-nav"></nav>
          <div class="settings-pane" id="settings-pane"></div>
        </div>
      </div>`;
    document.body.appendChild(overlay);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) overlay.remove(); });
    $('#settings-close').addEventListener('click', () => overlay.remove());

    const nav = $('#settings-nav');
    SETTINGS_SECTIONS.forEach((sec) => {
      const btn = document.createElement('button');
      btn.className = 'settings-nav-item';
      btn.dataset.section = sec.id;
      btn.innerHTML = `<span class="sn-ic">${sec.icon}</span> ${t(sec.label)}`;
      btn.addEventListener('click', () => openSettings(sec.id));
      nav.appendChild(btn);
    });
  } else {
    $('#settings-title').textContent = t('settings.title');
    $$('.settings-nav-item').forEach((btn) => {
      const sec = SETTINGS_SECTIONS.find((s) => s.id === btn.dataset.section);
      if (sec) btn.innerHTML = `<span class="sn-ic">${sec.icon}</span> ${t(sec.label)}`;
    });
  }

  const meta = SETTINGS_SECTIONS.find((s) => s.id === sectionId) || SETTINGS_SECTIONS[0];
  $('#settings-blurb').textContent = t(meta.blurb);
  $$('.settings-nav-item').forEach((b) => b.classList.toggle('active', b.dataset.section === sectionId));

  const pane = $('#settings-pane');
  pane.innerHTML = '';
  ({
    playlists: renderPlaylistSettings,
    language: renderLanguageSettings,
    general: renderGeneralSettings,
    downloads: renderDownloadSettings,
    appearance: renderAppearanceSettings,
    backup: renderBackupSettings,
    troubleshooting: renderTroubleshootingSettings,
    about: renderAboutSettings,
    updates: renderUpdatesSettings
  })[meta.id](pane);
}

// ---- Check for updates ----
async function renderUpdatesSettings(pane) {
  const currentVersion = await window.api.getAppVersion().catch(() => '-');
  pane.innerHTML = settingsCard(t('updates.title'), `
    <div class="settings-row">
      <div class="settings-row-text">
        <div class="sr-label">${t('updates.currentVersion')}: v${currentVersion}</div>
        <div class="sr-help" id="updates-status">${t('updates.upToDate')}</div>
      </div>
      <div class="settings-row-control">
        <button class="btn-primary" id="updates-check-btn">${t('updates.checkButton')}</button>
      </div>
    </div>
    <div id="updates-download-row" class="settings-row" hidden>
      <div class="settings-row-text">
        <div class="sr-label" id="updates-new-version"></div>
        <div class="sr-help" id="updates-notes"></div>
      </div>
      <div class="settings-row-control">
        <button class="btn-primary" id="updates-download-btn">${t('updates.downloadButton')}</button>
      </div>
    </div>`);

  const checkBtn = $('#updates-check-btn');
  const status = $('#updates-status');
  const downloadRow = $('#updates-download-row');

  checkBtn.addEventListener('click', async () => {
    checkBtn.disabled = true;
    downloadRow.hidden = true;
    let dots = 0;
    status.textContent = t('updates.checking');
    // A small animated ellipsis so "Checking..." doesn't look frozen while
    // the request is in flight — purely cosmetic, has no bearing on the
    // actual result once it comes back.
    const dotsTimer = setInterval(() => {
      dots = (dots + 1) % 4;
      status.textContent = t('updates.checking') + '.'.repeat(dots);
    }, 350);
    try {
      const info = await window.api.checkForUpdate();
      clearInterval(dotsTimer);
      if (info && info.available) {
        status.textContent = t('updates.available');
        $('#updates-new-version').textContent = `v${info.latestVersion}`;
        $('#updates-notes').innerHTML = renderSpecsMarkdown(info.notes);
        downloadRow.hidden = false;
        // Both rows get the "an update is waiting" highlight — the top one
        // ("Current version") is what actually caught the user's eye first
        // in testing, not just the download row below it.
        pane.querySelector('.settings-row').classList.add('settings-row-update-available');
        downloadRow.classList.add('settings-row-update-available');
        $('#updates-download-btn').onclick = () => {
          if (info.downloadUrl) window.api.openDownloadUrl(info.downloadUrl);
        };
      } else {
        status.textContent = t('updates.upToDate');
        // Reset back from a previous "update available" state (e.g. the
        // admin removed the published update, or this device already
        // updated) -- otherwise the Download row/highlight from an earlier
        // check just stayed stuck on screen.
        downloadRow.hidden = true;
        pane.querySelector('.settings-row').classList.remove('settings-row-update-available');
        downloadRow.classList.remove('settings-row-update-available');
      }
    } catch {
      clearInterval(dotsTimer);
      status.textContent = t('updates.error');
    } finally {
      checkBtn.disabled = false;
    }
  });
}

function settingsCard(title, bodyHtml) {
  return `<div class="settings-card"><div class="settings-card-title">${title}</div>${bodyHtml}</div>`;
}

function settingsRow(label, help, controlHtml) {
  return `<div class="settings-row">
      <div class="settings-row-text"><div class="sr-label">${label}</div><div class="sr-help">${help}</div></div>
      <div class="settings-row-control">${controlHtml}</div>
    </div>`;
}

function toggleHtml(id, on) {
  return `<button class="settings-toggle${on ? ' on' : ''}" id="${id}" role="switch" aria-checked="${on}"><span></span></button>`;
}

function selectHtml(id, value, options) {
  return `<select class="settings-select" id="${id}">${options
    .map(([v, label]) => `<option value="${v}"${v === String(value) ? ' selected' : ''}>${label}</option>`)
    .join('')}</select>`;
}

function bindToggle(id, key) {
  const el = $(`#${id}`);
  el.addEventListener('click', async () => {
    const next = !el.classList.contains('on');
    el.classList.toggle('on', next);
    el.setAttribute('aria-checked', String(next));
    await setSetting(key, next);
  });
}

function bindSelect(id, key, transform = (v) => v) {
  $(`#${id}`).addEventListener('change', async (e) => setSetting(key, transform(e.target.value)));
}

// ---- Playlists ----
function renderPlaylistSettings(pane) {
  const accounts = state.store.accounts || [];
  const rows = accounts.map((acc) => {
    const active = state.activeAccount && acc.id === state.activeAccount.id;
    return `<div class="pls-row${active ? ' active' : ''}" data-id="${acc.id}">
        <div class="pls-main">
          <div class="pls-name">${escapeHtml(acc.name)} ${active ? `<span class="pls-badge">${t('playlists.selected')}</span>` : ''}</div>
          <div class="pls-sub">${acc.type === 'xtream' ? t('playlists.xtream') : 'M3U'} · ${escapeHtml(acc.url)}</div>
        </div>
        <div class="pls-actions">
          ${active ? '' : `<button class="btn-mini" data-act="use" data-id="${acc.id}">${t('playlists.use')}</button>`}
          <button class="btn-mini danger" data-act="del" data-id="${acc.id}">${t('playlists.remove')}</button>
        </div>
      </div>`;
  }).join('') || `<div class="settings-empty">${t('playlists.empty')}</div>`;

  pane.innerHTML =
    settingsCard(`${t('playlists.yours')} (${accounts.length})`, rows) +
    settingsCard(t('playlists.add'), `
      <div class="pls-tabs">
        <button class="pls-tab active" data-kind="xtream">${t('playlists.xtream')}</button>
        <button class="pls-tab" data-kind="m3u">${t('playlists.m3u')}</button>
      </div>
      <div id="pls-form-xtream">
        <input class="settings-input" id="pls-x-url" placeholder="http://example.com:8080" />
        <div class="pls-two">
          <input class="settings-input" id="pls-x-user" placeholder="${t('playlists.username')}" />
          <input class="settings-input" id="pls-x-pass" placeholder="${t('playlists.password')}" type="password" />
        </div>
      </div>
      <div id="pls-form-m3u" hidden>
        <input class="settings-input" id="pls-m-name" placeholder="${t('playlists.playlistName')}" />
        <input class="settings-input" id="pls-m-url" placeholder="http://example.com/playlist.m3u" />
      </div>
      <div class="pls-add-foot">
        <span class="sr-help" id="pls-msg">${t('playlists.credentialsNote')}</span>
        <button class="btn-primary" id="pls-add">${t('playlists.addButton')}</button>
      </div>`);

  pane.querySelectorAll('[data-act="use"]').forEach((b) => b.addEventListener('click', () => {
    const acc = accounts.find((a) => a.id === b.dataset.id);
    document.getElementById('settings-modal').remove();
    if (acc) switchPlaylist(acc);
  }));

  pane.querySelectorAll('[data-act="del"]').forEach((b) => b.addEventListener('click', async () => {
    const acc = accounts.find((a) => a.id === b.dataset.id);
    if (!acc) return;
    if (state.activeAccount && acc.id === state.activeAccount.id) {
      alert('This playlist is in use. Switch to another one first.');
      return;
    }
    if (!confirm(`Remove "${acc.name}"?`)) return;
    state.store.accounts = state.store.accounts.filter((a) => a.id !== acc.id);
    await saveStore();
    renderSavedAccounts();
    openSettings('playlists');
  }));

  pane.querySelectorAll('.pls-tab').forEach((tab) => tab.addEventListener('click', () => {
    pane.querySelectorAll('.pls-tab').forEach((t) => t.classList.toggle('active', t === tab));
    $('#pls-form-xtream').hidden = tab.dataset.kind !== 'xtream';
    $('#pls-form-m3u').hidden = tab.dataset.kind !== 'm3u';
  }));

  $('#pls-add').addEventListener('click', async () => {
    const msg = $('#pls-msg');
    const isXtream = !$('#pls-form-xtream').hidden;
    let acc;
    if (isXtream) {
      let url = $('#pls-x-url').value.trim();
      const user = $('#pls-x-user').value.trim();
      const pass = $('#pls-x-pass').value.trim();
      if (!url || !user || !pass) { msg.textContent = 'Server, username and password are all required.'; return; }
      if (!/^https?:\/\//i.test(url)) url = 'http://' + url;
      if (state.store.accounts.some((a) => a.type === 'xtream' && a.url === url && a.username === user)) {
        msg.textContent = 'That playlist is already added.';
        return;
      }
      acc = { id: 'x_' + Date.now(), type: 'xtream', name: `${user} @ ${new URL(url).hostname}`, url, username: user, password: pass };
    } else {
      const url = $('#pls-m-url').value.trim();
      if (!url) { msg.textContent = 'An M3U URL is required.'; return; }
      if (state.store.accounts.some((a) => a.type === 'm3u' && a.url === url)) {
        msg.textContent = 'That playlist is already added.';
        return;
      }
      acc = { id: 'm_' + Date.now(), type: 'm3u', name: $('#pls-m-name').value.trim() || 'My Playlist', url };
    }

    // Only keep a playlist that actually connects, so a typo can't leave a
    // dead entry behind in the switcher.
    msg.textContent = 'Checking connection...';
    try {
      if (acc.type === 'xtream') await new XtreamClient(acc.url, acc.username, acc.password).authenticate();
      else await parseM3U(acc.url);
    } catch (err) {
      msg.textContent = `Could not connect: ${err.message || 'check the details'}`;
      return;
    }
    state.store.accounts.unshift(acc);
    await saveStore();
    renderSavedAccounts();
    openSettings('playlists');
  });
}

// ---- General ----
// ---- Language ----
function renderLanguageSettings(pane) {
  const s = settings();
  pane.innerHTML = settingsCard(t('settings.language.title'),
    settingsRow(t('settings.language.title'), t('settings.language.help'),
      selectHtml('set-language', s.language, LANGUAGES.map((l) => [l.code, l.name]))));
  bindSelect('set-language', 'language');
}

function renderGeneralSettings(pane) {
  const s = settings();
  pane.innerHTML =
    settingsCard('Startup', [
      settingsRow('Opening section', 'Which tab the app lands on after it loads.',
        selectHtml('set-start', s.startSection, [['live', 'Live TV'], ['movies', 'Movies'], ['series', 'Series']])),
      settingsRow('Time format', 'Used by the clock in the top bar.',
        selectHtml('set-time', s.timeFormat, [['system', 'Follow system'], ['12', '12-hour'], ['24', '24-hour']]))
    ].join('')) +
    settingsCard('Playback', [
      settingsRow('Resume where you left off', 'Continue movies and episodes from your last position.',
        toggleHtml('set-resume', s.resume)),
      settingsRow('Auto-play next episode', 'When an episode ends, start the next one in the season.',
        toggleHtml('set-autonext', s.autoNextEpisode)),
      settingsRow('Skip amount', 'How far the ◀◀ / ▶▶ buttons and arrow keys jump.',
        selectHtml('set-seekstep', s.seekStep, [['5', '5 seconds'], ['10', '10 seconds'], ['15', '15 seconds'], ['30', '30 seconds']])),
      settingsRow('Default quality', 'Videos above this start scaled down to it; anything at or below plays at its original resolution.',
        selectHtml('set-quality', s.quality, [['auto', 'Original (recommended)'], ['1080', 'Up to 1080p'], ['720', 'Up to 720p'], ['480', 'Up to 480p'], ['360', 'Up to 360p']]))
    ].join('')) +
    settingsCard('Content', [
      settingsRow('Hide adult categories', 'Filters categories named XXX / adult out of every section.',
        toggleHtml('set-adult', s.adultFilter))
    ].join(''));

  bindSelect('set-start', 'startSection');
  bindSelect('set-time', 'timeFormat');
  bindToggle('set-resume', 'resume');
  bindToggle('set-autonext', 'autoNextEpisode');
  bindSelect('set-seekstep', 'seekStep', (v) => parseInt(v, 10));
  bindSelect('set-quality', 'quality');
  $('#set-adult').addEventListener('click', async () => {
    const el = $('#set-adult');
    const next = !el.classList.contains('on');
    el.classList.toggle('on', next);
    await setSetting('adultFilter', next);
    state.itemCache = {};
    await switchSection(state.section);
  });
}

// ---- Appearance ----
function renderAppearanceSettings(pane) {
  const s = settings();
  pane.innerHTML =
    settingsCard('Theme', `<div class="theme-grid">
        ${[['dark', 'Dark'], ['midnight', 'Midnight'], ['light', 'Light']]
          .map(([v, label]) => `<button class="theme-chip${s.theme === v ? ' active' : ''}" data-theme="${v}"><span class="tc-dot ${v}"></span>${label}</button>`)
          .join('')}
      </div>`) +
    settingsCard('Grid', settingsRow('Poster size', 'How large the cards are in Movies and Series.',
      selectHtml('set-poster', s.posterSize, [['small', 'Small'], ['normal', 'Normal'], ['large', 'Large']])));

  pane.querySelectorAll('.theme-chip').forEach((chip) => chip.addEventListener('click', async () => {
    pane.querySelectorAll('.theme-chip').forEach((c) => c.classList.toggle('active', c === chip));
    await setSetting('theme', chip.dataset.theme);
  }));
  bindSelect('set-poster', 'posterSize');
}

// ---- Backup ----
function renderBackupSettings(pane) {
  pane.innerHTML =
    settingsCard('Export', `
      <div class="sr-help" style="margin-bottom:10px;">Saves playlists, favourites, watch history and settings to a file you can keep or move to another machine.</div>
      <label class="settings-check"><input type="checkbox" id="bk-creds" /> Include playlist passwords</label>
      <button class="btn-primary" id="bk-export" style="margin-top:12px;">Export backup…</button>`) +
    settingsCard('Import', `
      <div class="sr-help" style="margin-bottom:10px;">Restores from a backup file. Playlists are merged with what you already have; settings and history are replaced.</div>
      <input type="file" id="bk-file" accept="application/json" class="settings-input" />
      <div class="sr-help" id="bk-msg" style="margin-top:10px;"></div>`);

  $('#bk-export').addEventListener('click', () => {
    const withCreds = $('#bk-creds').checked;
    const data = JSON.parse(JSON.stringify(state.store));
    if (!withCreds) {
      (data.accounts || []).forEach((a) => { delete a.password; });
    }
    data._exportedAt = new Date().toISOString();
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `iptv-backup-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  });

  $('#bk-file').addEventListener('change', async (e) => {
    const file = e.target.files && e.target.files[0];
    if (!file) return;
    const msg = $('#bk-msg');
    try {
      const parsed = JSON.parse(await file.text());
      if (!parsed || typeof parsed !== 'object') throw new Error('not a backup file');
      const incoming = Array.isArray(parsed.accounts) ? parsed.accounts : [];
      const existing = state.store.accounts || [];
      const merged = existing.slice();
      let added = 0;
      incoming.forEach((acc) => {
        const dup = merged.some((a) => a.type === acc.type && a.url === acc.url && a.username === acc.username);
        if (!dup) { merged.push(acc); added++; }
      });
      state.store.accounts = merged;
      if (parsed.settings) state.store.settings = parsed.settings;
      if (Array.isArray(parsed.history)) state.store.history = parsed.history;
      if (parsed.favorites) state.store.favorites = parsed.favorites;
      await saveStore();
      applySettings();
      renderSavedAccounts();
      updateHistoryBadges();
      updateFavCount();
      msg.textContent = `Imported — ${added} new playlist${added === 1 ? '' : 's'} added.`;
    } catch (err) {
      msg.textContent = `Could not import: ${err.message || 'unreadable file'}`;
    }
  });
}

// ---- Troubleshooting ----
function renderTroubleshootingSettings(pane) {
  pane.innerHTML =
    settingsCard('Catalog', `
      <div class="sr-help" style="margin-bottom:10px;">Channels, movies and series are kept for 10 minutes so relaunching is quick. Refresh if your provider just changed something.</div>
      <button class="btn-primary" id="ts-refresh">🔄 Refresh catalog now</button>`) +
    settingsCard('Video cache', `
      <div class="sr-help" style="margin-bottom:10px;">While something plays it is cached on disk so seeking back is instant. It is cleared automatically when the app closes.</div>
      <div class="sr-help" id="ts-cache">Checking…</div>
      <button class="btn-primary" id="ts-clear" style="margin-top:12px;">Clear cached video</button>`) +
    settingsCard('Recent playback failures', `<div id="ts-fails"></div>`);

  const fails = (state.store.playbackFailures || []).slice(0, 8);
  $('#ts-fails').innerHTML = fails.length
    ? fails.map((f) => `<div class="ts-fail"><div class="pls-name">${escapeHtml(f.title || 'Unknown')}</div><div class="pls-sub">${escapeHtml(f.reason || '')} · ${new Date(f.at).toLocaleString()}</div></div>`).join('')
    : '<div class="settings-empty">Nothing has failed to play.</div>';

  const showCache = async () => {
    try {
      const info = await window.api.getCacheInfo();
      $('#ts-cache').textContent = `${info.files} file${info.files === 1 ? '' : 's'} · ${(info.bytes / 1048576).toFixed(1)} MB on disk`;
    } catch { $('#ts-cache').textContent = 'Cache size unavailable.'; }
  };
  showCache();

  $('#ts-refresh').addEventListener('click', async () => {
    state.itemCache = {};
    state.liveCats = state.movieCats = state.seriesCats = null;
    window.api.setCatalog(null).catch(() => {});
    await saveStore();
    document.getElementById('settings-modal').remove();
    await switchSection(state.section);
  });

  $('#ts-clear').addEventListener('click', async () => {
    try { await window.api.clearVideoCache(); } catch {}
    showCache();
  });
}

// ---- About ----
function renderAboutSettings(pane) {
  pane.innerHTML =
    settingsCard('This app', `
      <div class="pls-name">MY IPTV</div>
      <div class="pls-sub" id="ab-version">Version …</div>
      <div class="sr-help" style="margin-top:10px;">Plays your own playlists. No channels or content are provided by the app.</div>`) +
    settingsCard('Stored on this device', `<div class="sr-help" id="ab-storage">Counting…</div>`) +
    settingsCard('Account', `<button class="btn-primary danger" id="ab-logout">🚪 Log out</button>`);

  window.api.getAppVersion().then((v) => { $('#ab-version').textContent = `Version ${v}`; }).catch(() => {});
  const accounts = (state.store.accounts || []).length;
  const history = (state.store.history || []).length;
  const favs = Object.values(state.store.favorites || {}).reduce((n, arr) => n + (arr || []).length, 0);
  $('#ab-storage').textContent = `${accounts} playlist${accounts === 1 ? '' : 's'} · ${history} watched item${history === 1 ? '' : 's'} · ${favs} favourite${favs === 1 ? '' : 's'}`;

  $('#ab-logout').addEventListener('click', () => {
    document.getElementById('settings-modal').remove();
    $('#btn-logout').click();
  });
}

// ===================== Series Detail =====================
async function openSeries(series) {
  state.viewingDownloads = false;
  state.currentSeries = series;
  const grid = $('#item-grid');
  cancelPostersIn(grid);
  grid.innerHTML = '<div class="loading-state"><div class="spinner"></div><div>Loading episodes...</div></div>';

  let info;
  try {
    info = state.client ? await state.client.getSeriesInfo(series.series_id) : null;
  } catch (err) {
    grid.innerHTML = `
      <div class="error-state">
        <div class="err-icon">⚠️</div>
        <div class="err-msg">Could not load series info</div>
        <div>${escapeHtml(err.message || '')}</div>
        <button class="btn-retry" id="btn-retry-series">Retry</button>
      </div>`;
    $('#btn-retry-series').addEventListener('click', () => openSeries(series));
    return;
  }

  const seasons = info && info.episodes ? Object.keys(info.episodes) : [];
  const seasonInfo = (info && info.seasons) || [];

  // Continue-Watching / Up-Next: find this series' most recently touched
  // episode (if any) so we can offer a direct "Resume: Episode X" button
  // instead of making the user hunt through seasons for where they left off.
  const seriesHistory = historyList()
    .filter((h) => h.type === 'episode' && h.title === series.name)
    .sort((a, b) => b.updatedAt - a.updatedAt);
  const lastWatched = seriesHistory[0] || null;
  const epNumMatch = lastWatched && /Episode\s+(\d+)/i.exec(lastWatched.subtitle || '');
  const lastWatchedEpNum = epNumMatch ? epNumMatch[1] : null;
  const isFinishedEp = lastWatched && lastWatched.duration > 0 && lastWatched.resumeAt >= lastWatched.duration * 0.95;

  grid.innerHTML = `
    <div style="grid-column:1/-1">
      <div class="series-detail">
        <div class="series-poster" style="${series.cover ? `background-image:url('${thumbUrl(series.cover, 400)}')` : ''}"></div>
        <div class="series-info">
          <h2>${escapeHtml(series.name)}</h2>
          <p>${escapeHtml((info && info.info && info.info.plot) || '')}</p>
          <button class="btn-series-play" id="btn-series-play">
            ${lastWatched && !isFinishedEp
              ? `▶ Resume: Episode ${lastWatchedEpNum || ''}`
              : lastWatched
                ? `▶ Play Next Episode`
                : `▶ Play`}
          </button>
          ${lastWatched && !isFinishedEp
            ? `<button class="btn-series-play btn-series-restart" id="btn-series-restart">↺ Start New</button>`
            : ''}
        </div>
      </div>
      <div class="season-tabs" id="season-tabs"></div>
      <div id="episode-list"></div>
    </div>
  `;

  const seasonTabs = $('#season-tabs');
  const episodeList = $('#episode-list');

  if (!seasons.length) {
    episodeList.innerHTML = '<div class="empty-state">No episodes found.</div>';
    $('#btn-series-play').style.display = 'none';
    return;
  }

  $('#btn-series-play').addEventListener('click', () => {
    if (lastWatched && !isFinishedEp) {
      // Resume exactly where they left off — and remember which season list
      // that episode sits in, so the next one still follows on its own.
      state.episodeContext = null;
      for (const sNum of seasons) {
        const eps = info.episodes[sNum] || [];
        const index = eps.findIndex((ep) => lastWatched.url.includes(`/${ep.id}.`));
        if (index >= 0) { state.episodeContext = { series, seasonNum: sNum, list: eps, index }; break; }
      }
      openPlayer({
        url: lastWatched.url, isLive: false, type: 'episode',
        title: lastWatched.title, subtitle: lastWatched.subtitle, thumb: lastWatched.thumb,
        historyKey: lastWatched.key, resumeAt: lastWatched.resumeAt
      });
      return;
    }
    // Either brand new, or the last-watched episode is finished — start
    // from the very first episode instead of re-playing a finished one.
    const firstSeason = seasons[0];
    const firstEp = (info.episodes[firstSeason] || [])[0];
    if (firstEp) playEpisode(firstEp, series, firstSeason);
  });

  const restartBtn = $('#btn-series-restart');
  if (restartBtn) {
    restartBtn.addEventListener('click', () => {
      // Ignore the saved progress entirely and start episode 1 from 0:00.
      const firstSeason = seasons[0];
      const firstEp = (info.episodes[firstSeason] || [])[0];
      if (firstEp) playEpisode(firstEp, series, firstSeason, { resumeAt: 0 });
    });
  }

  function renderSeason(sNum) {
    seasonTabs.querySelectorAll('.season-tab').forEach((t) => t.classList.toggle('active', t.dataset.s === sNum));
    const eps = info.episodes[sNum] || [];
    cancelPostersIn(episodeList);
    episodeList.innerHTML = '';
    const episodeMeta = (ep) => ({
      url: state.client.seriesStreamUrl(ep.id, ep.container_extension || 'mp4'),
      type: 'episode',
      title: series.name,
      seriesName: series.name,
      subtitle: `Season ${sNum} - Episode ${ep.episode_num} - ${ep.title || ''}`,
      thumb: series.cover || ''
    });
    if (state.client && eps.length) {
      const bar = document.createElement('div');
      bar.className = 'season-dl-bar';
      bar.innerHTML = `<span>${eps.length} episode${eps.length === 1 ? '' : 's'}</span><button class="btn-mini" id="season-dl">⬇ Download season ${escapeHtml(String(sNum))}</button>`;
      bar.querySelector('#season-dl').addEventListener('click', async () => {
        const missing = eps.filter((ep) => !findDownload(episodeMeta(ep).url));
        if (!missing.length) { toast('This whole season is already in Downloads.'); return; }
        for (const ep of missing) await startDownload(episodeMeta(ep));
        toast(`${missing.length} episode${missing.length === 1 ? '' : 's'} added to Downloads — they download one after another.`);
      });
      episodeList.appendChild(bar);
    }
    eps.forEach((ep, epIndex) => {
      const row = document.createElement('div');
      row.className = 'episode-row';
      const thumb = usableArtwork((ep.info && ep.info.movie_image) || series.cover || '');
      row.innerHTML = `
        <div class="episode-thumb"${thumb ? ` data-bg="${thumbUrl(thumb, 200)}"` : ''}></div>
        <div class="episode-meta">
          <div class="ep-title">S${sNum} E${ep.episode_num} - ${escapeHtml(ep.title || '')}</div>
          <div class="ep-sub">${ep.info && ep.info.duration ? ep.info.duration : ''}</div>
        </div>
        ${state.client ? `<button class="icon-btn ep-dl" title="Download episode" data-url="${escapeHtml(episodeMeta(ep).url)}">⬇</button>` : ''}
      `;
      const dlBtn = row.querySelector('.ep-dl');
      if (dlBtn) {
        dlBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          const meta = episodeMeta(ep);
          if (findDownload(meta.url)) { openSettings('downloads'); return; }
          startDownload(meta);
        });
      }
      row.addEventListener('click', () => playEpisode(ep, series, sNum, { list: eps, index: epIndex }));
      episodeList.appendChild(row);
    });
    // Only the episodes actually on screen fetch their stills.
    observePosters(episodeList);
    updateEpisodeDownloadButtons();
  }

  seasons.forEach((sNum, i) => {
    const tab = document.createElement('button');
    tab.className = 'season-tab' + (i === 0 ? ' active' : '');
    tab.dataset.s = sNum;
    tab.textContent = 'Season ' + sNum;
    tab.addEventListener('click', () => renderSeason(sNum));
    seasonTabs.appendChild(tab);
  });

  renderSeason(seasons[0]);
}

// ===================== Downloads =====================
// Films and episodes saved to disk (see downloads.js). The main process
// pushes the whole list about once a second while something downloads, and
// every open view that shows downloads redraws from it.
state.downloads = [];

function fmtBytes(n) {
  if (!n || n < 0) return '0 MB';
  if (n >= 1073741824) return `${(n / 1073741824).toFixed(2)} GB`;
  if (n >= 1048576) return `${(n / 1048576).toFixed(n >= 104857600 ? 0 : 1)} MB`;
  return `${Math.max(1, Math.round(n / 1024))} KB`;
}

function fmtSpeed(bps) {
  if (!bps) return '—';
  return bps >= 1048576 ? `${(bps / 1048576).toFixed(1)} MB/s` : `${Math.round(bps / 1024)} KB/s`;
}

function fmtEta(sec) {
  if (sec === null || sec === undefined || !isFinite(sec)) return '';
  const s = Math.max(0, Math.round(sec));
  if (s < 60) return `${s} sec left`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min ${String(s % 60).padStart(2, '0')} sec left`;
  return `${Math.floor(m / 60)} hr ${String(m % 60).padStart(2, '0')} min left`;
}

function downloadStatusText(d) {
  const pct = `${Math.floor((d.progress || 0) * 100)}%`;
  const sizes = d.totalBytes ? `${fmtBytes(d.receivedBytes)} of ${fmtBytes(d.totalBytes)}` : fmtBytes(d.receivedBytes);
  switch (d.status) {
    case 'downloading': return `Downloading · ${pct} · ${sizes} · ${fmtSpeed(d.speed)}${d.eta !== null ? ` · ${fmtEta(d.eta)}` : ''}`;
    case 'waiting': return `Paused while you watch · ${pct} · ${sizes} — continues by itself afterwards`;
    case 'queued': return d.receivedBytes ? `Waiting to continue · ${pct} · ${sizes}` : 'Waiting — starts after the current download';
    case 'paused': return `Paused · ${pct} · ${sizes}`;
    case 'failed': return `Failed — ${d.error || 'unknown error'}`;
    case 'completed': return `Downloaded · ${fmtBytes(d.totalBytes || d.receivedBytes)}`;
    default: return d.status;
  }
}

function findDownload(url) {
  return state.downloads.find((d) => d.url === url) || null;
}

let toastTimer = null;
function toast(message) {
  let el = document.getElementById('app-toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'app-toast';
    el.className = 'app-toast';
    document.body.appendChild(el);
  }
  el.textContent = message;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2800);
}

async function startDownload(meta) {
  if (!meta || !/^https?:/i.test(meta.url || '')) return;
  const ext = ((meta.url.split('?')[0].match(/\.([a-z0-9]{2,4})$/i) || [])[1] || 'mp4').toLowerCase();
  const res = await window.api.downloadsAdd({
    url: meta.url, title: meta.title, subtitle: meta.subtitle || '', type: meta.type === 'episode' ? 'episode' : 'movie',
    seriesName: meta.seriesName || (meta.type === 'episode' ? meta.title : ''), thumb: meta.thumb || '', ext
  }).catch((err) => ({ ok: false, error: err.message }));
  if (!res || !res.ok) { toast(res && res.error ? res.error : 'Could not start the download.'); return; }
  const d = res.item;
  toast(d.status === 'completed' ? 'Already downloaded — find it in Downloads.' : `Added to Downloads: ${d.title}${d.subtitle ? ` · ${d.subtitle}` : ''}`);
}

async function playDownload(d) {
  const url = await window.api.downloadsFileUrl(d.id).catch(() => null);
  if (!url) { toast('The downloaded file is missing — it may have been moved or deleted.'); return; }
  state.episodeContext = null;
  openPlayer({
    url, isLive: false, type: d.type, title: d.title, subtitle: d.subtitle, thumb: d.thumb,
    historyKey: `download:${d.id}`, local: true
  });
}

async function removeDownload(d) {
  if (d.status === 'completed') {
    if (!confirm(`Delete "${d.title}${d.subtitle ? ` · ${d.subtitle}` : ''}" from this computer?`)) return;
    await window.api.downloadsRemove(d.id, true);
  } else {
    await window.api.downloadsRemove(d.id, false);
  }
}

function downloadRowHtml(d) {
  const pct = Math.floor((d.progress || 0) * 100);
  const running = d.status === 'downloading' || d.status === 'queued' || d.status === 'waiting';
  const art = usableArtwork(d.thumb);
  return `<div class="dl-row status-${d.status}" data-id="${d.id}">
      <div class="dl-thumb"${art ? ` style="background-image:url('${thumbUrl(art, 160)}')"` : ''}></div>
      <div class="dl-main">
        <div class="dl-title">${escapeHtml(d.title)}${d.subtitle ? ` <span class="dl-sub">· ${escapeHtml(d.subtitle)}</span>` : ''}</div>
        <div class="dl-status">${escapeHtml(downloadStatusText(d))}</div>
        ${d.status !== 'completed' ? `<div class="dl-bar"><div class="dl-bar-fill" style="width:${pct}%"></div></div>` : ''}
      </div>
      <div class="dl-actions">
        ${d.status === 'completed' ? '<button class="btn-mini" data-act="play">▶ Play</button><button class="btn-mini" data-act="folder">Show in folder</button>' : ''}
        ${running ? '<button class="btn-mini" data-act="pause">Pause</button>' : ''}
        ${d.status === 'paused' || d.status === 'failed' ? `<button class="btn-mini" data-act="resume">${d.status === 'failed' ? 'Retry' : 'Resume'}</button>` : ''}
        <button class="btn-mini danger" data-act="remove" title="${d.status === 'completed' ? 'Delete' : 'Cancel'}">${d.status === 'completed' ? 'Delete' : 'Cancel'}</button>
      </div>
    </div>`;
}

// Redraws a list of download rows. While only numbers change (the usual
// once-a-second update) the rows are patched in place, so buttons don't get
// swapped out from under the pointer.
function fillDownloadRows(host, list) {
  const rows = [...host.querySelectorAll('.dl-row')];
  const sameShape = rows.length === list.length
    && rows.every((row, i) => row.dataset.id === list[i].id && row.classList.contains('status-' + list[i].status));
  if (sameShape && rows.length) {
    rows.forEach((row, i) => {
      const d = list[i];
      const status = row.querySelector('.dl-status');
      if (status) status.textContent = downloadStatusText(d);
      const fill = row.querySelector('.dl-bar-fill');
      if (fill) fill.style.width = Math.floor((d.progress || 0) * 100) + '%';
    });
    return false;
  }
  return true;
}

function wireDownloadRows(root) {
  root.querySelectorAll('.dl-row [data-act]').forEach((btn) => btn.addEventListener('click', async (e) => {
    e.stopPropagation();
    const d = state.downloads.find((x) => x.id === btn.closest('.dl-row').dataset.id);
    if (!d) return;
    const act = btn.dataset.act;
    if (act === 'play') {
      const modal = document.getElementById('settings-modal');
      if (modal) modal.remove();
      playDownload(d);
    } else if (act === 'folder') window.api.downloadsOpenFolder(d.id);
    else if (act === 'pause') window.api.downloadsPause(d.id);
    else if (act === 'resume') window.api.downloadsResume(d.id);
    else if (act === 'remove') removeDownload(d);
  }));
}

// Whether a download keeps running while something plays online. Even on a
// one-connection account this holds up in practice: the provider now and
// then drops the download's connection, which reconnects by itself within a
// second and carries on from the same byte, while the film keeps playing
// (measured: 150 s of playback with a seek, no stall, download continuing
// at roughly half speed). "off" is there for providers stricter than that.
function downloadWhileWatchingActive() {
  return settings().downloadWhileWatching !== 'off';
}

function applyDownloadPolicy() {
  if (window.api.downloadsSetConcurrent) window.api.downloadsSetConcurrent(downloadWhileWatchingActive()).catch(() => {});
}

// Settings → Downloads
function renderDownloadSettings(pane) {
  pane.innerHTML =
    settingsCard('Download location', `
      <div class="dl-path" id="dl-path">…</div>
      <div class="dl-path-actions">
        <button class="btn-mini" id="dl-change">Change folder…</button>
        <button class="btn-mini" id="dl-open">Open folder</button>
      </div>
      <div class="sr-help" style="margin-top:10px;">Movies and episodes are saved here, to watch later without internet from <b>Downloads</b> in the sidebar.
        One download runs at a time, at the full speed your connection to the provider gives; more are queued and start by themselves.</div>`) +
    settingsCard('While watching online', `
      ${settingsRow('Keep downloading while watching',
        `Your account allows <b>${state.maxConnections || 1}</b> connection${(state.maxConnections || 1) === 1 ? '' : 's'} at a time. `
          + 'Downloads keep going while you watch; the speed is shared with the video, and if the provider briefly drops the download it reconnects by itself. '
          + 'If videos ever stall while something downloads, turn this off — downloads then pause while you watch and continue afterwards.',
        toggleHtml('dl-while', downloadWhileWatchingActive()))}`) +
    settingsCard('Downloads', '<div id="dl-settings-list"></div>');

  window.api.downloadsGetDir().then((dir) => { const el = document.getElementById('dl-path'); if (el) el.textContent = dir; }).catch(() => {});
  $('#dl-change').addEventListener('click', async () => {
    const res = await window.api.downloadsChooseDir().catch(() => null);
    if (!res) return;
    const el = document.getElementById('dl-path');
    if (el) el.textContent = res.dir;
    if (res.error) toast(res.error);
    else if (res.ok) toast('Download folder changed.');
  });
  $('#dl-open').addEventListener('click', () => window.api.downloadsOpenFolder(null));
  $('#dl-while').addEventListener('click', async () => {
    const el = $('#dl-while');
    const next = !el.classList.contains('on');
    el.classList.toggle('on', next);
    el.setAttribute('aria-checked', String(next));
    await setSetting('downloadWhileWatching', next ? 'on' : 'off');
    applyDownloadPolicy();
  });
  renderDownloadSettingsList();
}

function renderDownloadSettingsList() {
  const host = document.getElementById('dl-settings-list');
  if (!host) return;
  if (state.downloads.length && !fillDownloadRows(host, state.downloads)) return;
  host.innerHTML = state.downloads.length
    ? state.downloads.map(downloadRowHtml).join('')
    : '<div class="settings-empty">Nothing downloaded yet. Use ⬇ in the player, or on an episode, to save it for later.</div>';
  wireDownloadRows(host);
}

// Sidebar → Downloads
function showDownloadsView() {
  $$('.sb-quick').forEach((el) => el.classList.remove('active'));
  document.getElementById('sb-downloads').classList.add('active');
  $$('.tb-tab').forEach((t) => t.classList.remove('active'));
  $('#cat-list').innerHTML = '';
  $('#item-search').value = '';
  showItemGrid();
  state.viewingDownloads = true;
  renderDownloadsView();
}

function renderDownloadsView() {
  const grid = $('#item-grid');
  if (!state.viewingDownloads || !grid) return;
  const list = state.downloads;
  $('#content-title').textContent = 'Downloads';
  const done = list.filter((d) => d.status === 'completed').length;
  $('#content-sub').textContent = `${done} ready to watch offline${list.length > done ? ` · ${list.length - done} in progress` : ''}`;
  const existing = grid.querySelector('.dl-view');
  if (existing && list.length && !fillDownloadRows(existing, list)) return;
  cancelPostersIn(grid);
  grid.innerHTML = list.length
    ? `<div class="dl-view">${list.map(downloadRowHtml).join('')}</div>`
    : '<div class="empty-state">Nothing downloaded yet — use ⬇ in the player, or on an episode, to save it for watching offline.</div>';
  wireDownloadRows(grid);
  grid.querySelectorAll('.dl-row.status-completed').forEach((row) => row.addEventListener('click', () => {
    const d = state.downloads.find((x) => x.id === row.dataset.id);
    if (d) playDownload(d);
  }));
}

// The ⬇ button in the player's top bar reflects the current title.
function updatePlayerDownloadButton() {
  const btn = document.getElementById('p-download');
  if (!btn) return;
  const meta = state.nowPlaying;
  const eligible = meta && !meta.isLive && !meta.local && /^https?:/i.test(meta.url || '');
  btn.hidden = !eligible;
  if (!eligible) return;
  const d = findDownload(meta.url);
  btn.classList.toggle('active', !!d);
  if (!d) { btn.textContent = '⬇'; btn.title = 'Download to watch offline'; return; }
  if (d.status === 'completed') { btn.textContent = '✓'; btn.title = 'Downloaded'; return; }
  btn.textContent = `${Math.floor((d.progress || 0) * 100)}%`;
  btn.title = downloadStatusText(d);
}

// Episode rows show their own download state.
function updateEpisodeDownloadButtons() {
  document.querySelectorAll('.ep-dl[data-url]').forEach((btn) => {
    const d = findDownload(btn.dataset.url);
    btn.classList.toggle('active', !!d);
    btn.textContent = !d ? '⬇' : d.status === 'completed' ? '✓' : `${Math.floor((d.progress || 0) * 100)}%`;
    btn.title = !d ? 'Download episode' : downloadStatusText(d);
  });
}

function applyDownloadsUpdate(list) {
  state.downloads = Array.isArray(list) ? list : [];
  const count = document.getElementById('dl-count');
  if (count) count.textContent = state.downloads.length;
  renderDownloadSettingsList();
  renderDownloadsView();
  updatePlayerDownloadButton();
  updateEpisodeDownloadButtons();
  updateTopbarDownloadsButton();
}

// The topbar button is always visible (so it's obvious where downloads live
// even with nothing queued yet) and blinks red while something is actively
// downloading, so progress is visible from anywhere in the app, not just
// the Downloads screen or the player.
function updateTopbarDownloadsButton() {
  const btn = document.getElementById('tb-downloads');
  const dot = document.getElementById('tb-downloads-dot');
  if (!btn || !dot) return;
  const active = state.downloads.some((d) => d.status === 'downloading');
  const queued = state.downloads.some((d) => d.status === 'queued' || d.status === 'waiting');
  dot.hidden = !(active || queued);
  btn.classList.toggle('blinking', active);
  const done = state.downloads.filter((d) => d.status === 'completed').length;
  btn.title = active
    ? 'Downloading…'
    : queued
      ? 'Waiting to download'
      : done
        ? `Downloads (${done} ready to watch offline)`
        : 'Downloads';
}

function initDownloads() {
  $('#sb-downloads').addEventListener('click', showDownloadsView);
  $('#tb-downloads').addEventListener('click', () => {
    const modal = document.getElementById('settings-modal');
    if (modal) modal.remove();
    if (state.nowPlaying) { stopHistoryTracking(); if (player) player.destroy(); state.nowPlaying = null; }
    showView('app');
    showDownloadsView();
  });
  $('#p-download').addEventListener('click', (e) => {
    e.stopPropagation();
    const meta = state.nowPlaying;
    if (!meta) return;
    const d = findDownload(meta.url);
    if (d) { openSettings('downloads'); return; }
    startDownload(meta);
  });
  window.api.onDownloadsUpdate(applyDownloadsUpdate);
  window.api.downloadsList().then(applyDownloadsUpdate).catch(() => {});
}

// ===================== Playback =====================
let player;

// ===================== Live TV: inline preview + channel list =====================
// The inline preview and the fullscreen player share the SAME <video>
// element and the SAME PlayerController — "expanding" just moves that
// element into the fullscreen container (playback carries on uninterrupted,
// no reload). Using two separate players/video elements was what made
// "expand" restart the stream from a blank loading screen.
let currentPreviewChannel = null;
let liveListRowsByKey = new Map(); // stream_id -> row element, so a channel click doesn't have to re-render the whole (often 15,000+ channel) list

function renderLiveList() {
  const q = ($('#item-search').value || '').trim().toLowerCase();
  let items = state.items;
  if (q) items = items.filter((it) => (it.name || '').toLowerCase().includes(q));

  $('#content-sub').textContent = `${items.length} channels`;
  const list = $('#live-list');
  cancelPostersIn(list);
  list.innerHTML = '';
  liveListRowsByKey.clear();

  if (!items.length) {
    list.innerHTML = '<div class="empty-state">No channels found.</div>';
    return;
  }

  const frag = document.createDocumentFragment();
  items.forEach((ch) => {
    const row = document.createElement('div');
    const isActive = currentPreviewChannel && currentPreviewChannel.stream_id === ch.stream_id;
    row.className = 'live-row' + (isActive ? ' active' : '');
    const faved = isFavorite('live', ch);
    row.innerHTML = `
      <div class="live-row-logo"${ch.stream_icon ? ` data-bg="${thumbUrl(ch.stream_icon, 160)}"` : ''}></div>
      <div class="live-row-name">${escapeHtml(ch.name)}</div>
      ${ch.stream_icon ? '' : '<span class="live-row-badge">TV</span>'}
      <button class="live-row-fav${faved ? ' active' : ''}" title="Favorite">${faved ? '♥' : '♡'}</button>
    `;
    row.querySelector('.live-row-fav').addEventListener('click', (e) => {
      e.stopPropagation();
      toggleFavorite('live', ch);
      const btn = e.currentTarget;
      const nowFaved = isFavorite('live', ch);
      btn.classList.toggle('active', nowFaved);
      btn.textContent = nowFaved ? '♥' : '♡';
    });
    row.addEventListener('click', () => playLiveInline(ch));
    liveListRowsByKey.set(ch.stream_id, row);
    frag.appendChild(row);
  });
  list.appendChild(frag);
  // The channel list scrolls inside its own panel, so that panel is what
  // decides which logos are on screen.
  observePosters(list, list.closest('.live-list-wrap'));
}

let liveInlineWired = false;
function wireLiveInlineControlsOnce() {
  if (liveInlineWired) return;
  liveInlineWired = true;
  const video = $('#video');

  $('#live-playpause').addEventListener('click', () => player.togglePlayPause());
  $('#live-mute').addEventListener('click', () => {
    player.toggleMute();
    $('#live-mute').textContent = video.muted ? '🔇' : '🔊';
  });
  $('#live-expand').addEventListener('click', expandLiveToFullscreen);
  $('#live-preview').addEventListener('dblclick', expandLiveToFullscreen);
  video.addEventListener('play', () => { $('#live-playpause').textContent = '⏸'; });
  video.addEventListener('pause', () => { $('#live-playpause').textContent = '▶'; });
}

// Moves the single shared <video> into the fullscreen player view WITHOUT
// touching its src/playback state — same stream, same connection, just a
// different place in the DOM, so there's no reload/"Loading..." flash.
function expandLiveToFullscreen() {
  if (!currentPreviewChannel) return;
  const video = $('#video');
  $('#player-wrap').insertBefore(video, $('#player-wrap').firstChild);
  player.onStateChange = fullscreenStateHandler;

  const ch = currentPreviewChannel;
  state.nowPlaying = {
    url: video.currentSrc, isLive: true, type: 'live', title: ch.name, subtitle: 'Live TV',
    thumb: ch.stream_icon || '', favSection: 'live', favItem: ch, historyKey: `live:${ch.stream_id}`
  };
  $('#p-np-title').textContent = ch.name;
  $('#p-np-sub').textContent = 'Live TV';
  $('#p-np-thumb').style.backgroundImage = ch.stream_icon ? `url('${ch.stream_icon}')` : '';
  $('#p-fav').textContent = isFavorite('live', ch) ? '♥' : '♡';
  updatePlayerDownloadButton();
  $('#p-center-status').classList.remove('show');
  showView('player');
}

// Switches the channel while already in the fullscreen live player — same
// shared video/player instance as everywhere else in Live TV, so this is a
// source change, not a reload of the whole player view. Mirrors
// expandLiveToFullscreen's own state/UI updates, just without touching
// showView (we're already on it).
function switchLiveChannelFullscreen(channel) {
  const previousKey = currentPreviewChannel && currentPreviewChannel.stream_id;
  currentPreviewChannel = channel;
  if (previousKey != null) liveListRowsByKey.get(previousKey)?.classList.remove('active');
  liveListRowsByKey.get(channel.stream_id)?.classList.add('active');

  state.episodeContext = null;
  const url = state.client ? state.client.liveStreamUrl(channel.stream_id, 'm3u8') : channel.url;
  player.play(url, { isLive: true });

  state.nowPlaying = {
    url, isLive: true, type: 'live', title: channel.name, subtitle: 'Live TV',
    thumb: channel.stream_icon || '', favSection: 'live', favItem: channel, historyKey: `live:${channel.stream_id}`
  };
  $('#p-np-title').textContent = channel.name;
  $('#p-np-sub').textContent = 'Live TV';
  $('#p-np-thumb').style.backgroundImage = channel.stream_icon ? `url('${channel.stream_icon}')` : '';
  $('#p-fav').textContent = isFavorite('live', channel) ? '♥' : '♡';
  updatePlayerDownloadButton();
}

// Clicking the now-playing name/logo while watching a live channel in
// fullscreen opens a searchable list of every channel, so switching doesn't
// need backing out to the Live TV grid first.
function openFullscreenChannelPicker() {
  if (!state.nowPlaying || !state.nowPlaying.isLive) return;
  if (document.getElementById('live-channel-picker')) return;
  const allChannels = state.itemCache['live:all'] || [];

  const overlay = document.createElement('div');
  overlay.id = 'live-channel-picker';
  overlay.className = 'app-modal-overlay';
  overlay.innerHTML = `
    <div class="app-modal-card channel-picker-card">
      <input id="channel-picker-search" class="settings-input" placeholder="Search channels..." autocomplete="off" />
      <div id="channel-picker-list" class="channel-picker-list"></div>
    </div>`;
  document.body.appendChild(overlay);
  const closePicker = () => { cancelPostersIn(listEl); overlay.remove(); };
  overlay.addEventListener('click', (e) => { if (e.target === overlay) closePicker(); });

  const listEl = document.getElementById('channel-picker-list');
  const renderPickerList = (query) => {
    const q = (query || '').trim().toLowerCase();
    const items = q ? allChannels.filter((c) => (c.name || '').toLowerCase().includes(q)) : allChannels;
    listEl.innerHTML = items.slice(0, 500).map((ch) => `
      <div class="live-row" data-picker-id="${ch.stream_id}">
        <div class="live-row-logo"${ch.stream_icon ? ` data-bg="${thumbUrl(ch.stream_icon, 160)}"` : ''}></div>
        <div class="live-row-name">${escapeHtml(ch.name)}</div>
        ${ch.stream_icon ? '' : '<span class="live-row-badge">TV</span>'}
      </div>`).join('') || '<div class="empty-state">No channels found.</div>';
    listEl.querySelectorAll('[data-picker-id]').forEach((row) => {
      row.addEventListener('click', () => {
        const ch = allChannels.find((c) => String(c.stream_id) === row.dataset.pickerId);
        if (ch) switchLiveChannelFullscreen(ch);
        closePicker();
      });
    });
    observePosters(listEl, listEl);
  };
  renderPickerList('');
  const searchInput = document.getElementById('channel-picker-search');
  searchInput.addEventListener('input', () => renderPickerList(searchInput.value));
  searchInput.focus();
}

function playLiveInline(channel) {
  if (!player) initPlayer();
  wireLiveInlineControlsOnce();

  const previousKey = currentPreviewChannel && currentPreviewChannel.stream_id;
  currentPreviewChannel = channel;

  // O(1) active-row highlight instead of re-rendering the whole list (that
  // full re-render on every click was freezing the UI for a couple seconds
  // on large channel lists).
  if (previousKey != null) liveListRowsByKey.get(previousKey)?.classList.remove('active');
  liveListRowsByKey.get(channel.stream_id)?.classList.add('active');

  // Dock the shared video into the inline preview slot (no-op if it's
  // already there, e.g. coming back from a collapsed fullscreen view).
  const video = $('#video');
  const preview = $('#live-preview');
  if (video.parentElement !== preview) preview.insertBefore(video, preview.firstChild);

  $('#live-info').innerHTML = `
    <h3>${escapeHtml(channel.name)}</h3>
    <div class="live-info-cat">Live TV</div>
    <div class="live-info-label">Now</div>
    <div class="live-info-epg">Live broadcast — no program guide data from this provider.</div>
  `;

  player.onStateChange = inlineLiveStateHandler;

  const url = state.client ? state.client.liveStreamUrl(channel.stream_id, 'm3u8') : channel.url;
  player.setQuality((state.store.settings && state.store.settings.quality) || 'auto');
  player.play(url, { isLive: true });
}

function stopLivePreview() {
  if (player) player.destroy();
  if (currentPreviewChannel) liveListRowsByKey.get(currentPreviewChannel.stream_id)?.classList.remove('active');
  currentPreviewChannel = null;
}

function playLive(channel) {
  state.episodeContext = null;
  const url = state.client
    ? state.client.liveStreamUrl(channel.stream_id, 'm3u8')
    : channel.url;
  openPlayer({
    url,
    isLive: true,
    type: 'live',
    title: channel.name,
    subtitle: 'Live TV',
    thumb: channel.stream_icon || '',
    favSection: 'live',
    favItem: channel
  });
}

function playMovie(movie) {
  state.episodeContext = null; // auto-next only ever follows an episode list
  const ext = movie.container_extension || 'mp4';
  const url = state.client
    ? state.client.vodStreamUrl(movie.stream_id, ext)
    : movie.url;
  openPlayer({
    url,
    isLive: false,
    type: 'movie',
    title: movie.name,
    subtitle: 'Movie',
    thumb: movie.stream_icon || movie.cover || '',
    favSection: 'movies',
    favItem: movie
  });
}

function playEpisode(ep, series, seasonNum, opts = {}) {
  const ext = ep.container_extension || 'mp4';
  const url = state.client.seriesStreamUrl(ep.id, ext);
  // Remembered so playback can roll into the next episode on its own.
  state.episodeContext = { series, seasonNum, list: opts.list || null, index: opts.index };
  openPlayer({
    url,
    isLive: false,
    type: 'episode',
    title: series.name,
    subtitle: `Season ${seasonNum} - Episode ${ep.episode_num} - ${ep.title || ''}`,
    seriesName: series.name,
    thumb: series.cover || '',
    ...('resumeAt' in opts ? { resumeAt: opts.resumeAt } : {})
  });
}

function openPlayer(meta) {
  // Resume position: carried explicitly (from Continue Watching), or looked
  // up from history if we've watched this exact item before.
  if (meta.resumeAt === undefined) {
    const existing = findHistoryEntry(meta);
    meta.resumeAt = existing ? existing.resumeAt : 0;
  }

  state.nowPlaying = meta;
  updatePlayerDownloadButton();
  showView('player');

  // The shared <video> may currently be docked in the Live TV inline
  // preview (if the user came from browsing live channels) — move it back
  // into the fullscreen player before starting this new playback.
  const video = $('#video');
  const wrap = $('#player-wrap');
  if (video.parentElement !== wrap) wrap.insertBefore(video, wrap.firstChild);

  $('#p-np-title').textContent = meta.title;
  $('#p-np-sub').textContent = meta.subtitle;
  $('#p-np-thumb').style.backgroundImage = meta.thumb ? `url('${meta.thumb}')` : '';
  $('#p-center-status').className = 'p-center-status show';
  $('#p-center-status').innerHTML = '<div class="mini-spinner"></div>';
  $('#p-fav').textContent = (meta.favItem && isFavorite(meta.favSection, meta.favItem)) ? '♥' : '♡';

  if (!player) initPlayer();
  player.onStateChange = fullscreenStateHandler;
  const quality = (state.store.settings && state.store.settings.quality) || 'auto';
  player.setQuality(quality);
  player.preferredAudioLang = settings().audioLang || '';
  player.preferredSubtitleLang = settings().subtitleLang || '';

  // Reset seekbar so old video's time/duration doesn't linger during load.
  $('#p-time-cur').textContent = '00:00';
  $('#p-time-total').textContent = '00:00';
  $('#p-seek').value = 0;
  $('#p-seek-played').style.width = '0%';
  $('#p-seek-buffered').innerHTML = '';

  // The saved position goes to the player up front, so the stream opens
  // right there instead of starting at 0:00 and jumping once it loads.
  const startAt = !meta.isLive && settings().resume && meta.resumeAt > 5 ? meta.resumeAt : 0;
  meta._resumed = true;
  player.play(meta.url, { isLive: meta.isLive, startAt });

  if (!meta.isLive) startHistoryTracking(meta);
}

// Saves watch progress periodically (not on every timeupdate tick — that
// would hammer disk I/O) and once more when playback is closed.
let historySaveTimer = null;
function startHistoryTracking(meta) {
  stopHistoryTracking();
  const video = $('#video');
  historySaveTimer = setInterval(() => {
    const dur = player ? player.getDisplayDuration() : video.duration;
    const cur = player ? player.getDisplayCurrentTime() : video.currentTime;
    if (isFinite(dur) && dur > 0) {
      upsertHistory(meta, { resumeAt: cur, duration: dur });
    }
  }, 5000);
}
function stopHistoryTracking() {
  if (historySaveTimer) { clearInterval(historySaveTimer); historySaveTimer = null; }
  const video = $('#video');
  const meta = state.nowPlaying;
  const dur = player ? player.getDisplayDuration() : (video ? video.duration : NaN);
  const cur = player ? player.getDisplayCurrentTime() : (video ? video.currentTime : 0);
  if (video && meta && !meta.isLive && isFinite(dur) && dur > 0 && cur > 0) {
    upsertHistory(meta, { resumeAt: cur, duration: dur });
  }
}

// The shared player's onStateChange callback gets swapped depending on
// which UI is currently showing it (fullscreen player vs. the Live TV
// inline preview) — otherwise expanding/collapsing live channels would
// leave the wrong screen's "Loading..." indicator wired up.
function fullscreenStateHandler(status, extra) {
  const el = $('#p-center-status');
  if (status === 'loading' || status === 'buffering') {
    el.classList.add('show');
    el.innerHTML = `<div class="mini-spinner"></div>${extra ? `<div>${escapeHtml(extra)}</div>` : ''}`;
  } else if (status === 'playing') {
    el.classList.remove('show');
  } else if (status === 'error:final') {
    el.classList.add('show');
    el.innerHTML = `<div>${escapeHtml(extra || 'This stream could not be played.')}  —  tap Back and try again.</div>`;
  } else if (status === 'no-audio') {
    // The picture is fine — only tell the user, don't cover the video the
    // way an error would.
    toast(extra || 'This channel appears to have no audio in the broadcast.');
  }
}

function inlineLiveStateHandler(status, extra) {
  const el = $('#live-preview-status');
  if (status === 'playing') {
    el.hidden = true;
  } else if (status === 'loading' || status === 'buffering') {
    el.hidden = false;
    el.textContent = extra || 'Loading...';
  } else if (status === 'error:final') {
    el.hidden = false;
    el.textContent = extra || 'This channel could not be played.';
  } else if (status === 'no-audio') {
    toast(extra || 'This channel appears to have no audio in the broadcast.');
  }
}

let seekDragging = false;

// Leaving the player screen (Back / Stop). Fullscreen and picture-in-picture
// are closed first: the fullscreen element lives inside the player screen,
// so hiding that screen while still fullscreen left a black window over the
// app that only Esc got rid of — which looked like the app had frozen.
function leavePlayer() {
  seekDragging = false;
  const menu = document.getElementById('quality-menu');
  if (menu) menu.remove();
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
  stopHistoryTracking();
  if (player) player.destroy();
  state.nowPlaying = null;
  showView('app');
}

async function initPlayer() {
  const video = $('#video');
  player = new PlayerController(video);
  try {
    const base = await window.api.getProxyBase();
    player.setProxyBase(base);
  } catch { /* proxy playback simply won't be available as a fallback */ }

  player.onStateChange = fullscreenStateHandler;

  // Clicking the channel name/logo while watching live opens a searchable
  // list of every channel to switch to, right from the fullscreen player.
  $('#p-nowplaying').addEventListener('click', () => {
    if (state.nowPlaying && state.nowPlaying.isLive) openFullscreenChannelPicker();
  });

  video.addEventListener('play', () => { $('#p-playpause').textContent = '⏸'; });
  video.addEventListener('pause', () => { $('#p-playpause').textContent = '▶'; });

  video.addEventListener('ended', () => {
    if (!settings().autoNextEpisode) return;
    const ctx = state.episodeContext;
    if (!ctx || !ctx.list || typeof ctx.index !== 'number') return;
    const next = ctx.list[ctx.index + 1];
    if (!next) return;
    stopHistoryTracking();
    playEpisode(next, ctx.series, ctx.seasonNum, { list: ctx.list, index: ctx.index + 1, resumeAt: 0 });
  });
  // Waiting for the media element's own play/pause event to redraw the
  // button made every press feel late, because that event only arrives once
  // the decoder has actually reacted. The press is redrawn immediately and
  // the events above still correct it if playback refuses to start.
  video.addEventListener('waiting', () => { $('#p-playpause').textContent = video.paused ? '▶' : '⏸'; });

  video.addEventListener('timeupdate', () => {
    $('#p-subs').classList.toggle('active', !!player && player._subIndex >= 0);
    const isLive = state.nowPlaying && state.nowPlaying.isLive;
    const dur = player ? player.getDisplayDuration() : video.duration;
    if (isLive || !isFinite(dur)) {
      $('#p-time-cur').textContent = 'LIVE';
      $('#p-time-total').textContent = '';
      $('#p-seek').value = 0;
      $('#p-seek').disabled = true;
      $('#p-seek-played').style.width = '0%';
      $('#p-seek-buffered').innerHTML = '';
      return;
    }
    $('#p-seek').disabled = false;
    $('#p-time-total').textContent = fmtTime(dur);
    $('#p-seek').max = dur || 0;
    if (seekDragging) return; // don't yank the handle out from under the pointer
    const cur = player ? player.getDisplayCurrentTime() : video.currentTime;
    $('#p-time-cur').textContent = fmtTime(cur);
    $('#p-seek').value = Math.min(cur, dur);
    $('#p-seek-played').style.width = `${Math.min(100, (cur / dur) * 100)}%`;
  });

  let _bufferPollTimer = null;
  // ---- White "buffered" line on the seek bar — DO NOT weaken this logic ----
  //
  // This has broken twice before, both times the same way: something upstream
  // (MSE splicing several fetches together, or a proxied stream restarting)
  // leaves `video.buffered` holding many tiny, almost-touching ranges instead
  // of one clean span, and the bar renders as a row of slivers instead of a
  // solid line — which reads as "buffered range not working" even though the
  // data is technically all there. The fix is always the same: coalesce
  // ranges that are within a hair of each other before drawing, not to
  // "simplify" the drawing loop itself. If this ever needs touching again,
  // keep the merge step — dropping it is what caused the regressions.
  //
  // Draws every buffered span, not just one bar up to the playhead. What the
  // player holds IS the region a seek lands in without any wait, so showing
  // it exactly tells you how far ahead you can jump for free — and after a
  // jump the earlier span stays drawn, because going back there is free too.
  const updateBuffered = () => {
    const host = $('#p-seek-buffered');
    const dur = player ? player.getDisplayDuration() : video.duration;
    if (!isFinite(dur) || dur <= 0) { host.innerHTML = ''; return; }

    const offset = (player && player._seekOffset) || 0;
    const raw = [];
    for (let i = 0; i < video.buffered.length; i++) {
      const from = offset + video.buffered.start(i);
      const to = offset + video.buffered.end(i);
      if (to <= from) continue;
      raw.push([from, to]);
    }
    raw.sort((a, b) => a[0] - b[0]);

    // A gap under ~1.5s (or 0.5% of the film, whichever is bigger) is a
    // seam between two fetches, not a real hole in what's downloaded —
    // merging those is what keeps the bar one solid line instead of a
    // strip of slivers.
    const mergeGap = Math.max(1.5, dur * 0.005);
    const merged = [];
    for (const [from, to] of raw) {
      const last = merged[merged.length - 1];
      if (last && from - last[1] <= mergeGap) last[1] = Math.max(last[1], to);
      else merged.push([from, to]);
    }

    host.innerHTML = merged
      .map(([from, to]) => {
        const a = Math.max(0, (from / dur) * 100);
        const b = Math.min(100, (to / dur) * 100);
        return `<span style="left:${a.toFixed(3)}%;width:${Math.max(0, b - a).toFixed(3)}%"></span>`;
      })
      .join('');
  };
  video.addEventListener('progress', updateBuffered);
  video.addEventListener('timeupdate', updateBuffered);
  if (_bufferPollTimer) clearInterval(_bufferPollTimer);
  _bufferPollTimer = setInterval(updateBuffered, 1000);

  // Dragging only previews the position; the seek happens once, on release.
  // Seeking on every step of a drag used to open (and immediately abandon)
  // a new stream per pixel, and the last one often lost the race — playback
  // then carried on from somewhere else entirely.
  $('#p-seek').addEventListener('input', (e) => {
    seekDragging = true;
    const dur = player ? player.getDisplayDuration() : video.duration;
    if (!isFinite(dur) || dur <= 0) return;
    const target = Number(e.target.value);
    $('#p-time-cur').textContent = fmtTime(target);
    $('#p-seek-played').style.width = `${Math.min(100, (target / dur) * 100)}%`;
  });
  $('#p-seek').addEventListener('change', (e) => {
    seekDragging = false;
    if (state.nowPlaying && state.nowPlaying.isLive) return;
    const dur = player ? player.getDisplayDuration() : video.duration;
    if (!isFinite(dur) || dur <= 0) return;
    const target = Number(e.target.value);
    if (player) player.seekTo(target);
    else video.currentTime = target;
  });

  $('#p-playpause').addEventListener('click', () => {
    const { playing } = player.togglePlayPause();
    $('#p-playpause').textContent = playing ? '⏸' : '▶';
  });
  $('#p-rw').addEventListener('click', () => skipBy(-settings().seekStep));
  $('#p-fw').addEventListener('click', () => skipBy(settings().seekStep));
  $('#p-stop').addEventListener('click', leavePlayer);
  $('#p-back').addEventListener('click', leavePlayer);

  $('#p-vol').addEventListener('input', (e) => player.setVolume(Number(e.target.value)));
  $('#p-vol-btn').addEventListener('click', () => {
    player.toggleMute();
    $('#p-vol-btn').textContent = video.muted ? '🔇' : '🔊';
  });

  let speeds = [0.5, 1, 1.25, 1.5, 2];
  let speedIdx = 1;
  $('#p-speed').addEventListener('click', () => {
    speedIdx = (speedIdx + 1) % speeds.length;
    player.setSpeed(speeds[speedIdx]);
    $('#p-speed').textContent = speeds[speedIdx] + 'x';
  });

  const toggleFullscreen = () => {
    const wrap = $('#player-wrap');
    if (!document.fullscreenElement) wrap.requestFullscreen().catch(() => {});
    else document.exitFullscreen();
  };
  $('#p-fullscreen').addEventListener('click', toggleFullscreen);
  // Double-clicking the picture is what people reach for first.
  $('#player-wrap').addEventListener('dblclick', (e) => {
    if (e.target.closest('.player-overlay')) return; // let the controls be
    toggleFullscreen();
  });

  $('#p-settings').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleQualityMenu();
  });
  // The music-note button opens the same menu scrolled to its Audio part.
  $('#p-audio').addEventListener('click', (e) => {
    e.stopPropagation();
    toggleQualityMenu();
    const menu = document.getElementById('quality-menu');
    const head = menu && [...menu.querySelectorAll('.qm-head')].find((h) => h.textContent === 'Audio');
    if (head) head.scrollIntoView({ block: 'start' });
    else if (menu && !player.getAudioOptions().length) {
      menu.insertAdjacentHTML('beforeend', '<div class="qm-sep"></div><div class="qm-head">Audio</div><div class="qm-empty">This video has a single audio track.</div>');
    }
  });
  // The speech-bubble button switches subtitles on (in the language last
  // used, else the first available) and off again.
  $('#p-subs').addEventListener('click', (e) => {
    e.stopPropagation();
    const options = player.getSubtitleOptions();
    if (!options.length) {
      toggleQualityMenu();
      const menu = document.getElementById('quality-menu');
      if (menu) menu.insertAdjacentHTML('beforeend', '<div class="qm-sep"></div><div class="qm-head">Subtitles</div><div class="qm-empty">No subtitles in this video.</div>');
      return;
    }
    const on = options.find((o) => o.active && o.id >= 0);
    if (on) {
      player.selectSubtitle(-1);
      player.preferredSubtitleLang = '';
      setSetting('subtitleLang', '');
    } else {
      const pick = options.find((o) => o.id >= 0 && o.lang && o.lang === settings().subtitleLang) || options.find((o) => o.id >= 0);
      player.selectSubtitle(pick.id);
      player.preferredSubtitleLang = pick.lang || '';
      setSetting('subtitleLang', pick.lang || '');
    }
    $('#p-subs').classList.toggle('active', !on);
  });
  document.addEventListener('click', (e) => {
    const menu = document.getElementById('quality-menu');
    if (menu && !menu.contains(e.target)) menu.remove();
  });

  $('#p-pip').addEventListener('click', async () => {
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else await video.requestPictureInPicture();
    } catch {}
  });

  // Leaving the mini window (its expand button, or closing it) hands the
  // video back to the app, so the app should come forward with it rather
  // than staying buried behind whatever the user had open.
  video.addEventListener('leavepictureinpicture', () => {
    window.api.focusWindow().catch(() => {});
    showOverlay();
  });

  // The floating Picture-in-Picture window is drawn by Chromium itself, not
  // by us — it only shows play/pause/skip buttons if the page registers
  // Media Session action handlers. Without this, the mini window has no way
  // to seek ±10s (and even play/pause can misbehave), which is what made it
  // look "stuck".
  if ('mediaSession' in navigator) {
    navigator.mediaSession.setActionHandler('play', () => video.play().catch(() => {}));
    navigator.mediaSession.setActionHandler('pause', () => video.pause());
    navigator.mediaSession.setActionHandler('seekbackward', () => player.seekRelative(-10));
    navigator.mediaSession.setActionHandler('seekforward', () => player.seekRelative(10));
    try {
      navigator.mediaSession.setActionHandler('seekto', (details) => {
        if (details.seekTime != null) player.seekTo(details.seekTime);
      });
    } catch { /* not supported on all Chromium versions */ }
  }

  $('#p-fav').addEventListener('click', () => {
    const meta = state.nowPlaying;
    if (!meta || !meta.favItem) return; // nothing favoritable for this playback (e.g. a plain episode)
    toggleFavorite(meta.favSection, meta.favItem);
    $('#p-fav').textContent = isFavorite(meta.favSection, meta.favItem) ? '♥' : '♡';
  });

  // Auto-hide overlay
  const overlay = $('#player-overlay');
  let hideTimer;
  const showOverlay = () => {
    overlay.classList.remove('hide');
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => overlay.classList.add('hide'), 3500);
  };
  $('#player-wrap').addEventListener('mousemove', showOverlay);
  $('#player-wrap').addEventListener('click', showOverlay);
  showOverlay();

  // Keyboard controls
  document.addEventListener('keydown', (e) => {
    if (!state.nowPlaying) return;
    const view = document.getElementById('view-player');
    if (!view || !view.classList.contains('active')) return;
    switch (e.key) {
      case 'ArrowRight': e.preventDefault(); skipBy(settings().seekStep); showOverlay(); break;
      case 'ArrowLeft': e.preventDefault(); skipBy(-settings().seekStep); showOverlay(); break;
      case ' ': {
        e.preventDefault();
        const { playing } = player.togglePlayPause();
        $('#p-playpause').textContent = playing ? '⏸' : '▶';
        showOverlay();
        break;
      }
      case 'f': case 'F': case 'F11':
        e.preventDefault();
        if (!document.fullscreenElement) $('#player-wrap').requestFullscreen().catch(() => {});
        else document.exitFullscreen();
        break;
      case 'ArrowUp': e.preventDefault(); player.setVolume(Math.min(1, video.volume + 0.05)); showOverlay(); break;
      case 'ArrowDown': e.preventDefault(); player.setVolume(Math.max(0, video.volume - 0.05)); showOverlay(); break;
      case 'Escape':
        if (document.fullscreenElement) { e.preventDefault(); document.exitFullscreen(); }
        break;
    }
  });

  // Resuming is handled by openPlayer passing the saved position straight to
  // player.play(), which opens the stream at that point.
  video.addEventListener('loadedmetadata', () => {
    const h = video.videoHeight;
    $('#p-quality').textContent = h > 0 ? `${h}p` : '-';
  });

  player.onFps = (fps) => {
    $('#p-fps').textContent = fps === null || fps === undefined ? '-' : `${fps} FPS`;
  };
}

/// Lists what the current stream can genuinely play at — see
// PlayerController.getQualityOptions for how that set is decided — plus the
// film's own audio languages and subtitles, when it has more than one / any.
function toggleQualityMenu() {
  const existing = document.getElementById('quality-menu');
  if (existing) { existing.remove(); return; }

  const quality = player ? player.getQualityOptions() : [];
  const audio = player ? player.getAudioOptions() : [];
  const subs = player ? player.getSubtitleOptions() : [];
  const section = (title, kind, options) => `<div class="qm-head">${title}</div>` + options.map((o) => `
      <button class="qm-item${o.active ? ' active' : ''}" data-kind="${kind}" data-id="${escapeHtml(String(o.id))}" data-lang="${escapeHtml(o.lang || '')}">
        <span>${escapeHtml(o.label)}</span>${o.active ? '<span class="qm-check">✓</span>' : ''}
      </button>`).join('');

  const menu = document.createElement('div');
  menu.id = 'quality-menu';
  menu.className = 'quality-menu';
  menu.innerHTML = (quality.length ? section('Quality', 'quality', quality) : '<div class="qm-head">Quality</div><div class="qm-empty">Available once the video has started.</div>')
    + (audio.length ? '<div class="qm-sep"></div>' + section('Audio', 'audio', audio) : '')
    + (subs.length ? '<div class="qm-sep"></div>' + section('Subtitles', 'sub', subs) : '');
  $('#player-wrap').appendChild(menu);

  menu.querySelectorAll('.qm-item').forEach((btn) => btn.addEventListener('click', (e) => {
    e.stopPropagation();
    menu.remove();
    if (btn.classList.contains('active') || !player) return;
    const { kind, id, lang } = btn.dataset;
    if (kind === 'quality') {
      player.selectQuality(id);
    } else if (kind === 'audio') {
      player.selectAudio(Number(id));
      // Remembered, so the next film opens in the same language if it has it.
      player.preferredAudioLang = lang || '';
      setSetting('audioLang', lang || '');
    } else if (kind === 'sub') {
      const index = Number(id);
      player.selectSubtitle(index);
      player.preferredSubtitleLang = index >= 0 ? (lang || '') : '';
      setSetting('subtitleLang', index >= 0 ? (lang || '') : '');
    }
  }));
}


// Skips and shows the amount on screen. Repeated presses add up while the
// hint is still visible, so holding the key reads as one "+30" rather than
// three separate flashes.
let seekHintTimer = null;
let seekHintTotal = 0;
let seekHintDir = 0;
function skipBy(seconds) {
  if (!player) return;
  player.seekRelative(seconds);

  const dir = seconds > 0 ? 1 : -1;
  if (dir !== seekHintDir) seekHintTotal = 0;
  seekHintDir = dir;
  seekHintTotal += Math.abs(seconds);

  const el = $(dir > 0 ? '#seek-hint-right' : '#seek-hint-left');
  const other = $(dir > 0 ? '#seek-hint-left' : '#seek-hint-right');
  other.classList.remove('show');
  el.querySelector('.seek-hint-text').textContent = `${dir > 0 ? '+' : '−'}${seekHintTotal} sec`;
  el.classList.add('show');

  clearTimeout(seekHintTimer);
  seekHintTimer = setTimeout(() => {
    el.classList.remove('show');
    seekHintTotal = 0;
    seekHintDir = 0;
  }, 800);
}

function fmtTime(sec) {
  if (!isFinite(sec)) return '00:00';
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  const pad = (n) => String(n).padStart(2, '0');
  return h > 0 ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

// ===================== Splash Screen =====================
function splashSetProgress(pct, status) {
  const bar = document.getElementById('splash-progress-bar');
  const left = document.getElementById('splash-status-left');
  const sub = document.getElementById('splash-subtitle');
  if (bar) bar.style.width = `${Math.min(100, pct)}%`;
  if (left) left.textContent = status || '';
  if (sub) sub.textContent = status || 'Starting MY IPTV';
}
function splashSetRight(text) {
  const el = document.getElementById('splash-status-right');
  if (el) el.textContent = text || 'PLEASE WAIT';
}

async function preloadPosters(items, onProgress) {
  const total = items.length;
  let done = 0;
  const batchSize = 20;
  for (let i = 0; i < total; i += batchSize) {
    const batch = items.slice(i, i + batchSize);
    await Promise.allSettled(batch.map((item) => new Promise((resolve) => {
      const img = new Image();
      img.onload = img.onerror = resolve;
      // Same URL the grid will ask for, so this warms the thumbnail cache
      // rather than pulling the full-size original a second time.
      const art = usableArtwork(item.stream_icon || item.cover || item.logo || '');
      if (!art) { resolve(); return; }
      img.src = thumbUrl(art);
    })));
    done += batch.length;
    if (onProgress) onProgress(done, total);
  }
}

// Re-fetches the full catalog after the app has already opened from a fresh
// disk cache, so the cache doesn't go stale while the user is browsing and
// the *next* launch also gets to skip the splash's slow path. Runs quietly —
// no splash, no spinner; only touches itemCache once new data is in hand.
async function refreshCatalogInBackground(client, account) {
  try {
    const [liveCats, movieCats, seriesCats] = await Promise.all([
      client.getLiveCategories().catch(() => null),
      client.getVodCategories().catch(() => null),
      client.getSeriesCategories().catch(() => null)
    ]);
    const [liveItems, movieItems, seriesItems] = await Promise.all([
      client.getLiveStreams(null).catch(() => null),
      client.getVodStreams(null).catch(() => null),
      client.getSeries(null).catch(() => null)
    ]);
    if (![liveCats, movieCats, seriesCats, liveItems, movieItems, seriesItems].every((l) => Array.isArray(l) && l.length)) return;

    if (state.activeAccount === account) {
      state.liveCats = liveCats;
      state.movieCats = movieCats;
      state.seriesCats = seriesCats;
      state.itemCache['live:all'] = liveItems;
      state.itemCache['movies:all'] = sortByRecency(movieItems, 'movies');
      state.itemCache['series:all'] = sortByRecency(seriesItems, 'series');
    }

    await window.api.setCatalog({
      accountId: account.id,
      savedAt: Date.now(),
      liveCats, movieCats, seriesCats,
      liveItems, movieItems, seriesItems
    }).catch(() => {});
  } catch { /* stale cache just expires on its own next launch */ }
}

// ===================== License gate =====================
// Blocks the rest of the app (no splash, no login, nothing) until a valid
// key is verified. See CLAUDE.md / license-server/ for the full system.
let licensePlansCache = null;

async function updateProBadge() {
  try {
    const status = await window.api.licenseGetStatus();
    const badge = $('#pro-badge');
    badge.hidden = !status.valid;
    if (!status.valid || !status.expiresAt) { badge.textContent = 'PRO'; return; }
    const daysLeft = Math.ceil((status.expiresAt - Date.now()) / (24 * 60 * 60 * 1000));
    // Only worth calling out once it's close — a fresh 30/60/90-day key
    // doesn't need a running countdown cluttering the topbar every day.
    badge.textContent = daysLeft <= 7 ? `PRO · ${Math.max(daysLeft, 0)}d left` : 'PRO';
    badge.classList.toggle('pro-badge-warn', daysLeft <= 7);
  } catch { /* badge just stays hidden */ }
}

// *bold* is WhatsApp's own markdown (single asterisks), not the app's
// "**bold**" specs syntax — this is what actually renders bold once a
// message lands in the chat. Kept in sync with DEFAULT_WA_TEMPLATE in the
// theottdeals admin panel's admin-iptv.js — that's the same fallback text.
const DEFAULT_WA_TEMPLATE = `Hi TheOTTDeals! 👋\n\nI'd like to activate the *MY IPTV {plan}* ({price}, {duration}).\n\nPlease send me the activation details so I can get started.\n\nThank you!`;

// Opens WhatsApp (via the main process — renderer can't launch external
// apps directly) with a pre-filled message naming the chosen package. The
// message itself is admin-editable (theottdeals admin panel's WhatsApp
// Number section, "message_template") with {plan}/{price}/{duration}
// placeholders — falls back to a sensible default when nothing's been set.
async function openPackageOnWhatsApp(plan) {
  try {
    const res = await window.api.licenseGetSettings();
    const number = (res && res.settings && res.settings.whatsappNumber) || '';
    if (!number) {
      toast('WhatsApp number is not set up yet — please try again later.');
      return;
    }
    const template = (res.settings && res.settings.message_template) || DEFAULT_WA_TEMPLATE;
    const message = template
      .replace(/\{plan\}/g, plan.label)
      .replace(/\{price\}/g, formatPrice(plan.price, plan.currency))
      .replace(/\{duration\}/g, `${plan.duration_days} day(s)`);
    const url = `https://wa.me/${number}?text=${encodeURIComponent(message)}`;
    await window.api.openExternal(url);
  } catch {
    toast('Could not open WhatsApp — check your internet connection.');
  }
}

// Turns a plan's admin-set custom_bg fields (theottdeals admin panel's
// "Custom card background" color/gradient picker) into an inline style
// attribute — kept in sync with the admin panel's own planCardBackground()
// preview swatch (admin-iptv.js), same rule on both sides.
function planCardBackgroundStyle(p) {
  if (!p.custom_bg || !p.bg_color1) return '';
  const bg = (p.bg_type === 'gradient' && p.bg_color2)
    ? `linear-gradient(160deg, ${p.bg_color1}, ${p.bg_color2})`
    : p.bg_color1;
  return ` style="background:${bg}"`;
}

// Displays a price the way each currency is actually written, not just
// "<number> <code>" for everything — a symbol currency (USD) shows as
// "2$", a code currency (PKR, or anything else not in this map) keeps
// showing its code after the number.
const CURRENCY_SYMBOLS = { USD: '$' };
function formatPrice(price, currency) {
  const symbol = CURRENCY_SYMBOLS[String(currency || '').toUpperCase()];
  return symbol ? `${price}${symbol}` : `${price} ${currency}`;
}

// Renders a plan's/trial's optional "specs" text with the same lightweight
// formatting the admin typed in the panel's textarea — so what they write
// (### headings, **bold**, plain paragraphs) shows up looking the same way
// in the app instead of being flattened into a plain bullet list. Escapes
// HTML first (this is admin-authored, but still untrusted input as far as
// the renderer is concerned), then layers on just these three things:
// "### "/"## "/"# " headings, "**bold**", and blank-line-separated
// paragraphs (a single newline inside a paragraph becomes a <br>).
function renderSpecsMarkdown(specs) {
  if (!specs) return '';
  const escaped = escapeHtml(String(specs).trim());
  if (!escaped) return '';
  const withInline = escaped.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  const paragraphs = withInline.split(/\n\s*\n/).map((block) => {
    const heading = /^#{1,3}\s+(.+)$/.exec(block.trim());
    if (heading) return `<h4>${heading[1]}</h4>`;
    return `<p>${block.replace(/\n/g, '<br>')}</p>`;
  });
  return `<div class="plan-card-specs">${paragraphs.join('')}</div>`;
}

// Shared by the pre-login "See Plans" screen and the in-app "Upgrade Plans"
// popup (opened by clicking the PRO badge) — same cards, same Get
// Package/Get Free Trial wiring, just rendered into whichever container is
// passed in. `afterTrialClaim` lets each caller decide what happens once a
// trial is actually activated (the pre-login screen boots straight into the
// app; the in-app popup just closes and refreshes the badge).
async function renderPlansInto(host, { afterTrialClaim } = {}) {
  if (!host) return;
  // No "Loading..." placeholder: main.js answers license:getPlans /
  // checkTrialAvailability straight from its own in-memory cache (kept live
  // via an RTDB event stream, see startIptvLiveSync in main.js), so this is
  // effectively instant — there's nothing worth showing a spinner for.

  // Free trial availability/duration/specs and whether it's offered at all
  // are decided server-side (see trial:checkAvailability in main.js) — kept
  // in sync with getMachineId()'s hardware fingerprint, not anything stored
  // locally, specifically so reinstalling the app doesn't grant a second one.
  let trial = { available: false, enabled: false, specs: '', durationHours: 24 };
  try {
    const trialRes = await window.api.checkTrialAvailability();
    if (trialRes) trial = { available: !!trialRes.available, enabled: trialRes.enabled !== false, specs: trialRes.specs || '', durationHours: trialRes.durationHours || 24 };
  } catch { /* trial card just won't show */ }

  const trialDurationLabel = trial.durationHours % 24 === 0 ? `${trial.durationHours / 24} day(s)` : `${trial.durationHours} hour(s)`;
  const trialHtml = trial.enabled ? `
    <div class="plan-card plan-card-trial">
      <div class="plan-card-label">Free Trial</div>
      <div class="plan-card-price">${trialDurationLabel}<span class="plan-card-unit"> &middot; one per device</span></div>
      ${renderSpecsMarkdown(trial.specs)}
      <button class="btn-get-trial" data-trial-btn type="button" ${trial.available ? '' : 'disabled'}>${trial.available ? 'Get Free Trial' : 'You already used'}</button>
    </div>` : '';
  const trialMessageHtml = trial.enabled ? '<p data-trial-message class="login-error"></p>' : '';

  try {
    const res = await window.api.licenseGetPlans();
    licensePlansCache = (res && res.plans) || [];
  } catch { licensePlansCache = []; }

  const plansHtml = licensePlansCache.length
    ? licensePlansCache.map((p, i) => `
      <div class="plan-card"${planCardBackgroundStyle(p)}>
        <div class="plan-card-label">${p.label}</div>
        <div class="plan-card-price">${formatPrice(p.price, p.currency)}<span class="plan-card-unit"> &middot; ${p.duration_days} day(s)</span></div>
        ${renderSpecsMarkdown(p.specs)}
        <button class="btn-get-package" data-plan-index="${i}" type="button">Get Package</button>
      </div>
    `).join('')
    : (trialHtml ? '' : '<div class="license-subtitle">No plans available right now.</div>');

  host.innerHTML = `<div class="plans-grid">${trialHtml}${plansHtml}</div>${trialMessageHtml}`;

  host.querySelectorAll('.btn-get-package').forEach((btn) => {
    btn.addEventListener('click', () => {
      const plan = licensePlansCache[Number(btn.dataset.planIndex)];
      if (plan) openPackageOnWhatsApp(plan);
    });
  });

  const trialBtn = host.querySelector('[data-trial-btn]');
  if (trialBtn && !trialBtn.disabled) {
    trialBtn.addEventListener('click', async () => {
      trialBtn.disabled = true;
      trialBtn.textContent = 'Activating...';
      const msg = host.querySelector('[data-trial-message]');
      if (msg) msg.textContent = '';
      try {
        const res = await window.api.claimTrial();
        if (res.valid) {
          await updateProBadge();
          if (afterTrialClaim) afterTrialClaim(); else boot();
        } else if (res.reason === 'already-used') {
          trialBtn.textContent = 'You already used';
          if (msg) msg.textContent = 'This device has already used its free trial.';
        } else if (res.reason === 'disabled') {
          trialBtn.textContent = 'Not available';
          if (msg) msg.textContent = 'Free trial is not being offered right now.';
        } else {
          trialBtn.disabled = false;
          trialBtn.textContent = 'Get Free Trial';
          if (msg) msg.textContent = 'Could not activate trial — check your internet connection.';
        }
      } catch {
        trialBtn.disabled = false;
        trialBtn.textContent = 'Get Free Trial';
        if (msg) msg.textContent = 'Could not activate trial — check your internet connection.';
      }
    });
  }
}

async function renderPlansScreen() {
  await renderPlansInto($('#plans-list'));
}

// Opened by clicking the PRO badge in the topbar — a compact popup (not the
// full-screen pre-login plans view) showing the current plan's status plus
// the same upgrade cards, so a customer whose plan is about to run out can
// upgrade without leaving whatever they're doing.
async function showProPlanModal() {
  if (document.getElementById('app-pro-modal')) return;
  let statusHtml = '<div class="license-subtitle">Loading your plan...</div>';
  try {
    const status = await window.api.licenseGetStatus();
    if (status.valid && status.expiresAt) {
      const daysLeft = Math.max(0, Math.ceil((status.expiresAt - Date.now()) / (24 * 60 * 60 * 1000)));
      statusHtml = `
        <div class="pro-modal-current">
          <div class="pro-modal-current-label">Your plan</div>
          <div class="pro-modal-current-name">${status.plan || 'PRO'}</div>
          <div class="pro-modal-current-expiry">${daysLeft} day(s) left &middot; expires ${new Date(status.expiresAt).toLocaleDateString()}</div>
        </div>`;
    }
  } catch { /* show the cards anyway even if the status read failed */ }

  const overlay = document.createElement('div');
  overlay.id = 'app-pro-modal';
  overlay.className = 'app-modal-overlay';
  overlay.innerHTML = `
    <div class="app-modal-card pro-modal-card">
      <button class="icon-btn pro-modal-close" id="pro-modal-close">✕</button>
      ${statusHtml}
      <div class="pro-modal-heading">Upgrade Plans</div>
      <div id="pro-modal-plans"></div>
    </div>`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) overlay.remove(); });
  document.getElementById('pro-modal-close').addEventListener('click', () => overlay.remove());
  renderPlansInto(document.getElementById('pro-modal-plans'), { afterTrialClaim: () => overlay.remove() });
}

function licenseSetError(msg) {
  const el = $('#license-error');
  if (el) el.textContent = msg || '';
}

function initLicenseGate() {
  const btn = $('#btn-license-verify');
  const input = $('#license-key-input');
  const seePlansBtn = $('#btn-see-plans');
  const backBtn = $('#btn-plans-back');
  if (seePlansBtn) seePlansBtn.addEventListener('click', () => { showView('plans'); renderPlansScreen(); });
  if (backBtn) backBtn.addEventListener('click', () => showView('license'));
  if (!btn || !input) return;
  const submit = async () => {
    const key = input.value.trim();
    if (!key) { licenseSetError('Enter a license key.'); return; }
    licenseSetError('');
    btn.disabled = true;
    btn.textContent = 'Verifying...';
    try {
      const res = await window.api.licenseVerify(key);
      if (res.valid) {
        await updateProBadge();
        boot();
      } else {
        const messages = {
          'not-found': 'This key was not found.',
          'expired': 'Your plan has ended. Click "See Plans" to activate a new plan. Thank you.',
          'revoked': 'Your plan has ended. Click "See Plans" to activate a new plan. Thank you.',
          'wrong-device': 'This key is already active on another device.',
          'device-limit-reached': 'This key has reached its device limit.',
          'network-error': 'Could not reach the license server. Check your internet connection.'
        };
        licenseSetError(messages[res.reason] || 'Invalid license key.');
      }
    } catch {
      licenseSetError('Something went wrong. Please try again.');
    } finally {
      btn.disabled = false;
      btn.textContent = 'Verify';
    }
  };
  btn.addEventListener('click', submit);
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
}

// Every 2 minutes while the app is open, ask the server (not just the local
// cache) whether this key is still valid — a read-only check, doesn't touch
// device slots (see checkKeyStatusOnly in main.js). This is what makes a
// revoke from the admin panel actually kick an already-running app back to
// the license screen within a couple of minutes instead of the next day
// (main.js's own background revalidation only runs once/day).
function armLicenseWatch() {
  setInterval(async () => {
    try {
      const status = await window.api.licenseRecheckNow();
      if (!status.valid) {
        showView('license');
      } else {
        updateProBadge();
      }
    } catch { /* ignore — don't lock the user out over a transient error */ }
  }, 2 * 60 * 1000);
}

// ===================== Announcement =====================
// Admin-set message from the theottdeals MY IPTV panel (iptv/announcement
// in RTDB). Shown once per announcement — dismissing it records that
// announcement's createdAt in the local store so it doesn't reappear on
// every launch, but a genuinely NEW announcement (different createdAt)
// shows again even if an older one was dismissed.
async function checkAnnouncement() {
  try {
    const res = await window.api.getAnnouncement();
    const ann = res && res.announcement;
    if (!ann || !ann.text) return;
    const lastSeen = (state.store.settings && state.store.settings.lastSeenAnnouncementAt) || 0;
    if (ann.created_at && ann.created_at <= lastSeen) return;
    showAnnouncementModal(ann);
  } catch { /* offline — just skip, try again next check */ }
}

function showAnnouncementModal(ann) {
  if (document.getElementById('app-announcement')) return;
  const overlay = document.createElement('div');
  overlay.id = 'app-announcement';
  overlay.className = 'app-modal-overlay';
  // Star rating + comment only appear when the admin turned on
  // "collect_feedback" for this specific announcement — most announcements
  // (maintenance notices etc.) don't need it and just get the OK button.
  const feedbackHtml = ann.collect_feedback ? `
    <div class="ann-stars" id="ann-stars">
      ${[1, 2, 3, 4, 5].map((n) => `<button type="button" class="ann-star" data-star="${n}">★</button>`).join('')}
    </div>
    <textarea id="ann-comment" class="settings-input ann-comment" rows="2" placeholder="Anything you'd like to add? (optional)"></textarea>` : '';
  overlay.innerHTML = `
    <div class="app-modal-card">
      <div class="app-modal-title">Announcement</div>
      <div class="app-modal-body ann-body">${String(ann.text).replace(/</g, '&lt;')}</div>
      ${feedbackHtml}
      <button class="btn-primary" id="app-announcement-close">OK</button>
    </div>`;
  document.body.appendChild(overlay);

  let selectedStars = 0;
  if (ann.collect_feedback) {
    const starButtons = overlay.querySelectorAll('.ann-star');
    const paintStars = (n) => starButtons.forEach((b) => b.classList.toggle('filled', Number(b.dataset.star) <= n));
    starButtons.forEach((btn) => {
      btn.addEventListener('mouseenter', () => paintStars(Number(btn.dataset.star)));
      btn.addEventListener('click', () => { selectedStars = Number(btn.dataset.star); paintStars(selectedStars); });
    });
    overlay.querySelector('#ann-stars').addEventListener('mouseleave', () => paintStars(selectedStars));
  }

  document.getElementById('app-announcement-close').addEventListener('click', async () => {
    if (ann.collect_feedback && selectedStars > 0) {
      const comment = overlay.querySelector('#ann-comment')?.value || '';
      window.api.submitAnnouncementReview(selectedStars, comment, ann.created_at || null).catch(() => {});
    }
    overlay.remove();
    state.store.settings = state.store.settings || {};
    state.store.settings.lastSeenAnnouncementAt = ann.created_at || Date.now();
    await saveStore();
  });
}

// ===================== Update check =====================
function versionGt(a, b) {
  const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff > 0;
  }
  return false;
}

async function checkForUpdate() {
  try {
    const info = await window.api.checkForUpdate();
    if (!info || !info.available) return;
    if (info.forceUpdate) {
      showForceUpdateScreen(info);
    } else {
      showUpdateBanner(info);
    }
  } catch { /* offline — just skip, try again next check */ }
}

function showUpdateBanner(info) {
  if (document.getElementById('app-update-banner')) return;
  const bar = document.createElement('div');
  bar.id = 'app-update-banner';
  bar.className = 'app-update-banner';
  bar.innerHTML = `
    <span>A new version (${info.latestVersion}) is available.</span>
    <button class="btn-primary" id="app-update-download">Download Update</button>
    <button class="icon-btn" id="app-update-dismiss">✕</button>`;
  document.body.appendChild(bar);
  document.getElementById('app-update-download').addEventListener('click', () => {
    if (info.downloadUrl) window.api.openDownloadUrl(info.downloadUrl);
  });
  document.getElementById('app-update-dismiss').addEventListener('click', () => bar.remove());
}

// A forced update blocks the app entirely (admin "shut down this version"),
// same idea as the license gate — no close button, no way around it besides
// downloading and installing the newer build.
function showForceUpdateScreen(info) {
  if (document.getElementById('app-force-update')) return;
  const overlay = document.createElement('div');
  overlay.id = 'app-force-update';
  overlay.className = 'app-modal-overlay app-modal-overlay-solid';
  overlay.innerHTML = `
    <div class="app-modal-card">
      <div class="app-modal-title">Update Required</div>
      <div class="app-modal-body">A new version (${info.latestVersion}) is required to keep using MY IPTV.</div>
      ${info.notes ? renderSpecsMarkdown(info.notes) : ''}
      <button class="btn-primary" id="app-force-update-download">Download Update</button>
    </div>`;
  document.body.appendChild(overlay);
  document.getElementById('app-force-update-download').addEventListener('click', () => {
    if (info.downloadUrl) window.api.openDownloadUrl(info.downloadUrl);
  });
}

// ===================== Boot =====================
async function boot() {
  await loadStore();
  // Needed before the first grid renders so posters can go through the
  // downscaling proxy rather than pulling full-size artwork.
  try { state.thumbBases = await window.api.getThumbBases(); } catch { state.thumbBases = []; }
  state.thumbBase = (state.thumbBases && state.thumbBases[0]) || null;
  initLoginTabs();
  initLoginForm();
  initSearchBoxes();
  initTabBar();
  initClock();
  initLogout();
  initSettings();
  initQuickLists();
  initDownloads();
  initPlaylistSwitcher();
  applySettings();
  updateHistoryBadges();
  updateFavCount();
  renderSavedAccounts();

  const active = state.store.accounts.find((a) => a.id === state.store.activeAccountId);
  if (active) {
    showView('splash');
    splashSetProgress(10, 'Connecting...');
    splashSetRight('PLEASE WAIT');
    try {
      if (active.type === 'xtream') {
        const client = new XtreamClient(active.url, active.username, active.password);
        splashSetProgress(10, 'Authenticating...');
        const auth = await client.authenticate();
        state.client = client;
        state.activeAccount = active;
        state.store.activeAccountId = active.id;
        await saveStore();

        // If we fetched this same account's full catalog recently, skip
        // straight to the app instead of re-downloading everything — the
        // splash screen used to always run the full categories+items+images
        // sequence even when nothing could have changed in the last few
        // minutes, which is what made relaunching the app feel just as slow
        // as the very first run.
        const cache = await window.api.getCatalog().catch(() => null);
        const cacheIsFresh = cache && cache.accountId === active.id
          && (Date.now() - cache.savedAt) < DATA_CACHE_TTL_MS;

        if (cacheIsFresh) {
          splashSetProgress(70, 'Loading from cache...');
          // Anything missing from the snapshot is simply fetched when its tab
          // is opened.
          const nonEmpty = (list) => (Array.isArray(list) && list.length ? list : null);
          state.liveCats = nonEmpty(cache.liveCats);
          state.movieCats = nonEmpty(cache.movieCats);
          state.seriesCats = nonEmpty(cache.seriesCats);
          if (nonEmpty(cache.liveItems)) state.itemCache['live:all'] = cache.liveItems;
          if (nonEmpty(cache.movieItems)) state.itemCache['movies:all'] = sortByRecency(cache.movieItems, 'movies');
          if (nonEmpty(cache.seriesItems)) state.itemCache['series:all'] = sortByRecency(cache.seriesItems, 'series');
          splashSetProgress(100, 'Ready!');
          enterApp(auth);
          // Refresh the catalog in the background so the next launch (and
          // this session, once it lands) has current data — the user is
          // already in the app by the time this resolves.
          refreshCatalogInBackground(client, active);
          return;
        }

        // Each step below reports the fraction of *actual* work done so
        // far (categories fetched, items fetched per section, images
        // decoded) rather than a fixed guess — so the bar reflects what's
        // really happening instead of just animating on a timer.
        const totalSteps = 6; // categories, live items, movie items, series items, images, done
        let stepsDone = 0;
        const stepProgress = (label) => {
          stepsDone++;
          splashSetProgress(10 + Math.round((stepsDone / totalSteps) * 90), label);
        };

        const mySeq = ++state.loadSeq;
        // A request that fails is retried once, and if it still fails it is
        // left out (null) rather than stored as an empty list — an empty list
        // would be served as "0 items" for as long as the cache lasts.
        const fetchList = (fn) => fn().then((d) => (Array.isArray(d) ? d : null)).catch(() => null)
          .then((d) => d || new Promise((r) => setTimeout(r, 800)).then(() => fn()).then((x) => (Array.isArray(x) ? x : null)).catch(() => null));
        const [liveCats, movieCats, seriesCats] = await Promise.all([
          fetchList(() => client.getLiveCategories()),
          fetchList(() => client.getVodCategories()),
          fetchList(() => client.getSeriesCategories())
        ]);
        state.liveCats = liveCats;
        state.movieCats = movieCats;
        state.seriesCats = seriesCats;
        stepProgress('Loading categories...');

        const liveItems = await fetchList(() => client.getLiveStreams(null));
        stepProgress('Loading channels...');
        let movieItems = await fetchList(() => client.getVodStreams(null));
        stepProgress('Loading movies...');
        let seriesItems = await fetchList(() => client.getSeries(null));
        stepProgress('Loading series...');
        if (movieItems && movieItems.length) movieItems = sortByRecency(movieItems, 'movies');
        if (seriesItems && seriesItems.length) seriesItems = sortByRecency(seriesItems, 'series');

        // Seed the item cache with everything just fetched so switching
        // between Live/Movies/Series tabs right after boot is instant —
        // otherwise switchSection() would immediately re-fetch the exact
        // same "all" list over the network and flash a loading spinner.
        if (liveItems && liveItems.length) state.itemCache['live:all'] = liveItems;
        if (movieItems && movieItems.length) state.itemCache['movies:all'] = movieItems;
        if (seriesItems && seriesItems.length) state.itemCache['series:all'] = seriesItems;

        const toPreload = [...(liveItems || []).slice(0, 60), ...(movieItems || []).slice(0, 60), ...(seriesItems || []).slice(0, 60)];
        await preloadPosters(toPreload, (done, total) => {
          const pct = 10 + Math.round(((stepsDone + done / total) / totalSteps) * 90);
          splashSetProgress(pct, `Loading images (${done}/${total})`);
        });
        stepProgress('Ready!');

        // Only a complete snapshot is worth starting from next time.
        const complete = [liveCats, movieCats, seriesCats, liveItems, movieItems, seriesItems]
          .every((list) => Array.isArray(list) && list.length);
        if (complete) {
          await window.api.setCatalog({
            accountId: active.id,
            savedAt: Date.now(),
            liveCats, movieCats, seriesCats,
            liveItems, movieItems, seriesItems
          }).catch(() => {});
        }

        enterApp(auth);
      } else if (active.type === 'm3u') {
        splashSetProgress(30, 'Loading playlist...');
        const items = await parseM3U(active.url);
        state.client = null;
        state.activeAccount = active;
        state.m3uItems = items;
        state.store.activeAccountId = active.id;
        await saveStore();

        splashSetProgress(70, 'Preloading images...');
        await preloadPosters(items.slice(0, 80), (done, total) => {
          const pct = 70 + Math.round((done / total) * 30);
          splashSetProgress(pct, `Loading images (${done}/${total})`);
        });

        splashSetProgress(100, 'Ready!');
        await new Promise((r) => setTimeout(r, 300));
        enterAppM3U();
      }
    } catch (err) {
      console.error('[splash] error:', err);
      showView('login');
    }
  } else {
    showView('login');
  }
}

// Re-checked every 30 minutes while the app is open — an admin publishing a
// new announcement or update doesn't require the user to restart the app.
// This is now mostly a safety net: armIptvLiveUpdates (below) reacts to the
// same things instantly via a live push from main.js.
function armAnnouncementAndUpdateWatch() {
  setInterval(() => {
    checkAnnouncement();
    checkForUpdate();
  }, 30 * 60 * 1000);
}

// Pushed from main.js the instant plans/settings/trial-config/announcement/
// update changes on the server (it keeps its own live RTDB stream open —
// see startIptvLiveSync in main.js). If the plans screen happens to be open
// right now, this is what makes an admin edit show up on it in real time
// with the screen still open, not just "correct next time you open it".
function armIptvLiveUpdates() {
  window.api.onIptvCacheUpdated(() => {
    if (document.getElementById('view-plans')?.classList.contains('active')) {
      renderPlansScreen();
    }
    checkAnnouncement();
    checkForUpdate();
  });
}

// Pushed from the main process the instant its live RTDB stream sees this
// key end (revoked, or its expires_at patched into the past) — cuts
// straight to the license screen even mid-playback, no waiting for the
// 2-minute poll. See startLicenseStream in main.js.
function armLicenseInvalidationPush() {
  window.api.onLicenseInvalidated(() => {
    if (state.nowPlaying) { stopHistoryTracking(); state.nowPlaying = null; }
    // Covers both the fullscreen player and the inline Live TV preview
    // (a separate code path that shares the same underlying <video>/player
    // instance) — either one could be the thing actually making sound.
    stopLivePreview();
    showView('license');
  });
}

async function startup() {
  await loadStore();
  applyLanguage(settings().language);
  initLicenseGate();
  armLicenseInvalidationPush();
  armLicenseWatch();
  armIptvLiveUpdates();
  $('#pro-badge')?.addEventListener('click', showProPlanModal);
  let status;
  try { status = await window.api.licenseGetStatus(); } catch { status = { valid: false }; }
  if (!status.valid) {
    showView('license');
    return;
  }
  await updateProBadge();
  checkAnnouncement();
  checkForUpdate();
  armAnnouncementAndUpdateWatch();
  boot();
}

startup();
