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
  nowPlaying: null,
  filteredItems: [],
  renderedCount: 0,
  loadSeq: 0 // guards against a slow/stale category fetch landing after the user has already moved on
};

const PAGE_SIZE = 120;
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
  showView('app');
  $('#account-name').textContent = state.activeAccount.username;
  const exp = auth.user_info.exp_date;
  $('#account-sub').textContent = exp && exp !== null ? `Expires: ${new Date(exp * 1000).toLocaleDateString()}` : 'Xtream Codes';
  switchSection('live');
}

function enterAppM3U() {
  showView('app');
  $('#account-name').textContent = state.activeAccount.name;
  $('#account-sub').textContent = 'M3U Playlist';
  switchSection('live');
}

// ===================== Sections / Categories =====================
async function switchSection(section) {
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

async function loadItemsForCategory(catId) {
  const key = cacheKey(catId);
  const section = state.section; // frozen for this call — see the race-guard note below

  // Guards against a real bug that was showing Live channels / Movies while
  // browsing Series: if the user switches section/category again before an
  // earlier fetch resolves, that OLD (now-stale) response would still land
  // and overwrite state.items with the WRONG content type. Bumping this on
  // every call — cache-hit or not — means only the most recently started
  // load is ever allowed to apply its result.
  const mySeq = ++state.loadSeq;

  // Serve from cache instantly (feels instant, no spinner flash)
  if (state.itemCache[key]) {
    state.items = state.itemCache[key];
    renderGrid();
    return;
  }

  setGridLoading();
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
  grid.innerHTML = '';

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

function renderCard(it, sectionOverride) {
  const section = sectionOverride || state.section;
  const card = document.createElement('div');
  const isChannel = section === 'live';
  card.className = 'card' + (isChannel ? ' channel' : '');

  const name = it.name || it.title || 'Unknown';
  const img = it.stream_icon || it.cover || it.logo || '';
  const rating = it.rating_5based ? (it.rating_5based * 2).toFixed(1) : (it.rating ? Number(it.rating).toFixed(1) : null);
  const faved = isFavorite(section, it);

  // A real <img loading="lazy"> instead of an always-eager CSS
  // background-image — with thousands of posters in a list, loading every
  // single one immediately was saturating the connection and making all of
  // them crawl in together instead of the visible ones appearing quickly.
  card.innerHTML = `
    <div class="card-thumb">${img ? `<img src="${img}" loading="lazy" decoding="async" alt="" />` : escapeHtml(name)}
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

  const list = favoritesList();
  $('#content-title').textContent = 'Favorites';
  $('#content-sub').textContent = `${list.length} items`;

  const grid = $('#item-grid');
  grid.innerHTML = '';
  if (!list.length) {
    grid.innerHTML = '<div class="empty-state">No favorites yet — tap the ♡ on any channel, movie or series.</div>';
    return;
  }

  list.forEach((f) => grid.appendChild(renderCard(f.item, f.section)));
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

  const list = historyList();
  const items = kind === 'continue'
    ? list.filter((h) => !h.isLive && h.duration > 0 && h.resumeAt > 5 && h.resumeAt < h.duration * 0.95)
    : list;

  $('#content-title').textContent = kind === 'continue' ? 'Continue Watching' : 'Recently Watched';
  $('#content-sub').textContent = `${items.length} items`;

  const grid = $('#item-grid');
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
      <div class="card-thumb" style="${h.thumb ? `background-image:url('${h.thumb}')` : ''}">${h.thumb ? '' : escapeHtml(h.title)}</div>
      <div class="card-title">${escapeHtml(h.title)}</div>
      ${pct > 0 ? `<div class="card-progress"><div class="card-progress-fill" style="width:${pct.toFixed(0)}%"></div></div>` : ''}
    `;
    card.addEventListener('click', () => openPlayer({
      url: h.url, isLive: h.isLive, title: h.title, subtitle: h.subtitle, thumb: h.thumb,
      type: h.type, historyKey: h.key, replay: h.replay, resumeAt: h.resumeAt
    }));
    grid.appendChild(card);
  });
}

function initClock() {
  const update = () => {
    const now = new Date();
    $('#clock-time').textContent = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    $('#clock-date').textContent = now.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
  };
  update();
  setInterval(update, 30000);
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

// ===================== Settings Modal =====================
function initSettings() {
  $('#btn-settings').addEventListener('click', openSettingsModal);
}

function openSettingsModal() {
  if (document.getElementById('settings-modal')) return;

  const overlay = document.createElement('div');
  overlay.id = 'settings-modal';
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:999;';

  const acc = state.activeAccount || {};
  const isXtream = acc.type === 'xtream';

  overlay.innerHTML = `
    <div style="width:420px;background:var(--bg-2);border:1px solid var(--border);border-radius:14px;padding:22px;">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
        <h3 style="font-size:16px;">Settings</h3>
        <button id="settings-close" class="icon-btn">✕</button>
      </div>

      <div style="font-size:12px;color:var(--text-dim);margin-bottom:6px;">Account</div>
      <div style="background:var(--bg-3);border-radius:8px;padding:10px 12px;font-size:13px;margin-bottom:16px;">
        <div><strong>${escapeHtml(acc.name || acc.username || 'Playlist')}</strong></div>
        ${isXtream ? `<div style="color:var(--text-dim);font-size:11px;margin-top:3px;">${escapeHtml(acc.url)}</div>` : ''}
      </div>

      <div style="font-size:12px;color:var(--text-dim);margin-bottom:6px;">Playback quality</div>
      <select id="settings-quality" style="width:100%;padding:9px 10px;background:var(--bg-3);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:13px;margin-bottom:16px;">
        <option value="auto">Auto (recommended)</option>
        <option value="480">480p</option>
        <option value="720">720p (HD)</option>
        <option value="1080">1080p (Full HD)</option>
        <option value="2160">4K (2160p)</option>
      </select>

      <div style="font-size:12px;color:var(--text-dim);margin-bottom:6px;">Data</div>
      <button id="settings-refresh" class="btn-retry" style="width:100%;margin-bottom:8px;background:var(--bg-3);color:var(--text);">🔄 Refresh channels / movies / series</button>
      <button id="settings-logout" class="btn-retry" style="width:100%;background:var(--danger);">🚪 Logout</button>

      <div style="text-align:center;margin-top:16px;color:var(--text-dim);font-size:11px;" id="settings-version">Version -</div>
    </div>
  `;

  document.body.appendChild(overlay);

  $('#settings-quality').value = (state.store.settings && state.store.settings.quality) || 'auto';
  window.api.getAppVersion().then((v) => { $('#settings-version').textContent = `Version ${v}`; }).catch(() => {});

  const close = () => overlay.remove();
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  $('#settings-close').addEventListener('click', close);

  $('#settings-quality').addEventListener('change', async (e) => {
    state.store.settings = state.store.settings || {};
    state.store.settings.quality = e.target.value;
    await saveStore();
    if (player) player.setQuality(e.target.value);
  });

  $('#settings-refresh').addEventListener('click', async () => {
    state.itemCache = {};
    state.liveCats = state.movieCats = state.seriesCats = null;
    close();
    await switchSection(state.section);
  });

  $('#settings-logout').addEventListener('click', () => {
    close();
    $('#btn-logout').click();
  });
}

// ===================== Series Detail =====================
async function openSeries(series) {
  state.currentSeries = series;
  const grid = $('#item-grid');
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
        <div class="series-poster" style="${series.cover ? `background-image:url('${series.cover}')` : ''}"></div>
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
      // Resume exactly where they left off.
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

  function renderSeason(sNum) {
    seasonTabs.querySelectorAll('.season-tab').forEach((t) => t.classList.toggle('active', t.dataset.s === sNum));
    const eps = info.episodes[sNum] || [];
    episodeList.innerHTML = '';
    eps.forEach((ep) => {
      const row = document.createElement('div');
      row.className = 'episode-row';
      const thumb = (ep.info && ep.info.movie_image) || series.cover || '';
      row.innerHTML = `
        <div class="episode-thumb" style="${thumb ? `background-image:url('${thumb}')` : ''}"></div>
        <div class="episode-meta">
          <div class="ep-title">S${sNum} E${ep.episode_num} - ${escapeHtml(ep.title || '')}</div>
          <div class="ep-sub">${ep.info && ep.info.duration ? ep.info.duration : ''}</div>
        </div>
      `;
      row.addEventListener('click', () => playEpisode(ep, series, sNum));
      episodeList.appendChild(row);
    });
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
      <div class="live-row-logo" style="${ch.stream_icon ? `background-image:url('${ch.stream_icon}')` : ''}"></div>
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
  $('#p-center-status').classList.remove('show');
  showView('player');
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

function playEpisode(ep, series, seasonNum) {
  const ext = ep.container_extension || 'mp4';
  const url = state.client.seriesStreamUrl(ep.id, ext);
  openPlayer({
    url,
    isLive: false,
    type: 'episode',
    title: series.name,
    subtitle: `Season ${seasonNum} - Episode ${ep.episode_num} - ${ep.title || ''}`,
    thumb: series.cover || ''
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

  // Reset seekbar so old video's time/duration doesn't linger during load.
  $('#p-time-cur').textContent = '00:00';
  $('#p-time-total').textContent = '00:00';
  $('#p-seek').value = 0;
  $('#p-seek-played').style.width = '0%';
  $('#p-seek-buffered').style.width = '0%';

  player.play(meta.url, { isLive: meta.isLive });

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
  }
}

async function initPlayer() {
  const video = $('#video');
  player = new PlayerController(video);
  try {
    const base = await window.api.getProxyBase();
    player.setProxyBase(base);
  } catch { /* proxy playback simply won't be available as a fallback */ }

  player.onStateChange = fullscreenStateHandler;

  video.addEventListener('play', () => { $('#p-playpause').textContent = '⏸'; });
  video.addEventListener('pause', () => { $('#p-playpause').textContent = '▶'; });

  video.addEventListener('timeupdate', () => {
    const isLive = state.nowPlaying && state.nowPlaying.isLive;
    const dur = player ? player.getDisplayDuration() : video.duration;
    if (isLive || !isFinite(dur)) {
      $('#p-time-cur').textContent = 'LIVE';
      $('#p-time-total').textContent = '';
      $('#p-seek').value = 0;
      $('#p-seek').disabled = true;
      $('#p-seek-played').style.width = '0%';
      $('#p-seek-buffered').style.width = '0%';
      return;
    }
    $('#p-seek').disabled = false;
    const cur = player ? player.getDisplayCurrentTime() : video.currentTime;
    $('#p-time-cur').textContent = fmtTime(cur);
    $('#p-time-total').textContent = fmtTime(dur);
    $('#p-seek').max = dur || 0;
    $('#p-seek').value = Math.min(cur, dur);
    $('#p-seek-played').style.width = `${Math.min(100, (cur / dur) * 100)}%`;
  });

  let _bufferPollTimer = null;
  const updateBuffered = () => {
    const dur = player ? player.getDisplayDuration() : video.duration;
    if (!isFinite(dur) || dur <= 0) {
      $('#p-seek-buffered').style.width = '0%';
      return;
    }
    let bufferedEnd = 0;
    const cur = video.currentTime;
    if (video.buffered && video.buffered.length > 0) {
      for (let i = 0; i < video.buffered.length; i++) {
        if (video.buffered.start(i) <= cur + 1) {
          bufferedEnd = Math.max(bufferedEnd, video.buffered.end(i));
        }
      }
    }
    if (player && player._stage && player._stage.startsWith('proxy')) {
      const offset = player._seekOffset || 0;
      const total = offset + bufferedEnd;
      if (total > 0 && dur > 0) {
        $('#p-seek-buffered').style.width = `${Math.min(100, (total / dur) * 100)}%`;
      }
    } else {
      if (bufferedEnd > 0 && dur > 0) {
        $('#p-seek-buffered').style.width = `${Math.min(100, (bufferedEnd / dur) * 100)}%`;
      }
    }
  };
  video.addEventListener('progress', updateBuffered);
  video.addEventListener('timeupdate', updateBuffered);
  if (_bufferPollTimer) clearInterval(_bufferPollTimer);
  _bufferPollTimer = setInterval(updateBuffered, 1000);

  $('#p-seek').addEventListener('input', (e) => {
    if (isFinite(video.duration) && !(state.nowPlaying && state.nowPlaying.isLive)) {
      const target = Number(e.target.value);
      if (player && player._stage && player._stage.startsWith('proxy')) {
        player.seekTo(target);
      } else {
        video.currentTime = target;
      }
    }
  });

  $('#p-playpause').addEventListener('click', () => player.togglePlayPause());
  $('#p-rw').addEventListener('click', () => player.seekRelative(-10));
  $('#p-fw').addEventListener('click', () => player.seekRelative(10));
  $('#p-stop').addEventListener('click', () => { stopHistoryTracking(); player.destroy(); showView('app'); });
  $('#p-back').addEventListener('click', () => { stopHistoryTracking(); player.destroy(); showView('app'); });

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

  $('#p-fullscreen').addEventListener('click', () => {
    const wrap = $('#player-wrap');
    if (!document.fullscreenElement) wrap.requestFullscreen().catch(() => {});
    else document.exitFullscreen();
  });

  $('#p-pip').addEventListener('click', async () => {
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else await video.requestPictureInPicture();
    } catch {}
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
        if (details.seekTime != null && isFinite(video.duration)) video.currentTime = details.seekTime;
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
      case 'ArrowRight': e.preventDefault(); player.seekRelative(10); showOverlay(); break;
      case 'ArrowLeft': e.preventDefault(); player.seekRelative(-10); showOverlay(); break;
      case ' ': e.preventDefault(); player.togglePlayPause(); showOverlay(); break;
      case 'f': case 'F':
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

  video.addEventListener('loadedmetadata', () => {
    const h = video.videoHeight;
    $('#p-quality').textContent = h > 0 ? `${h}p` : '-';

    // Resume where we left off, once per playback (guarded by a flag on
    // nowPlaying so a mid-stream ffmpeg-fallback reload doesn't re-seek).
    // Goes through player.seekTo() rather than setting video.currentTime
    // directly — a proxied (ffmpeg) stream can only "seek" by restarting
    // at the target timestamp, which seekTo() knows how to do; the native
    // path still just assigns currentTime under the hood.
    const meta = state.nowPlaying;
    const dur = player.getDisplayDuration();
    if (meta && !meta.isLive && meta.resumeAt > 5 && !meta._resumed && isFinite(dur)) {
      if (meta.resumeAt < dur * 0.97) {
        player.seekTo(meta.resumeAt);
      }
      meta._resumed = true;
    }
  });

  player.onFps = (fps) => {
    $('#p-fps').textContent = fps === null || fps === undefined ? '-' : `${fps} FPS`;
  };
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
  if (sub) sub.textContent = status || 'Starting IPTV Player';
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
      img.src = item.cover || item.stream_icon || '';
    })));
    done += batch.length;
    if (onProgress) onProgress(done, total);
  }
}

// ===================== Boot =====================
async function boot() {
  await loadStore();
  initLoginTabs();
  initLoginForm();
  initSearchBoxes();
  initTabBar();
  initClock();
  initLogout();
  initSettings();
  initQuickLists();
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
        splashSetProgress(20, 'Authenticating...');
        const auth = await client.authenticate();
        state.client = client;
        state.activeAccount = active;
        state.store.activeAccountId = active.id;
        await saveStore();

        splashSetProgress(35, 'Loading categories...');
        const mySeq = ++state.loadSeq;
        const [liveCats, movieCats, seriesCats] = await Promise.all([
          client.getLiveCategories().catch(() => []),
          client.getVodCategories().catch(() => []),
          client.getSeriesCategories().catch(() => [])
        ]);
        state.liveCats = liveCats;
        state.movieCats = movieCats;
        state.seriesCats = seriesCats;

        splashSetProgress(55, 'Loading channels...');
        const liveItems = await client.getLiveStreams(null).catch(() => []);
        splashSetProgress(70, 'Loading movies...');
        const movieItems = await client.getVodStreams(null).catch(() => []);

        splashSetProgress(85, 'Preloading images...');
        await preloadPosters([...liveItems.slice(0, 60), ...movieItems.slice(0, 60)], (done, total) => {
          const pct = 85 + Math.round((done / total) * 15);
          splashSetProgress(pct, `Loading images (${done}/${total})`);
        });

        splashSetProgress(100, 'Ready!');
        await new Promise((r) => setTimeout(r, 300));

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

boot();
