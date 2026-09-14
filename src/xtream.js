// Xtream Codes API client — runs in renderer, uses window.api (preload) to avoid CORS.
class XtreamClient {
  constructor(baseUrl, username, password) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.username = username;
    this.password = password;
  }

  api(action, extra = '') {
    return `${this.baseUrl}/player_api.php?username=${encodeURIComponent(this.username)}&password=${encodeURIComponent(this.password)}${action ? `&action=${action}` : ''}${extra}`;
  }

  async authenticate() {
    const res = await window.api.getJson(this.api(''));
    if (!res.ok) throw new Error(res.error || 'Login failed: no response from server');
    const data = res.data;
    if (!data || !data.user_info) throw new Error('Invalid response from server');
    if (data.user_info.auth === 0 || data.user_info.auth === '0') {
      throw new Error('Invalid username or password');
    }
    if (data.user_info.status && data.user_info.status !== 'Active') {
      throw new Error(`Account status: ${data.user_info.status}`);
    }
    return data; // { user_info, server_info }
  }

  async _getOrThrow(url, fallback) {
    const res = await window.api.getJson(url);
    if (!res.ok) throw new Error(res.error || 'Could not reach the server');
    if (res.data === null || res.data === undefined) return fallback;
    return res.data;
  }

  async getLiveCategories() {
    return this._getOrThrow(this.api('get_live_categories'), []);
  }
  async getLiveStreams(categoryId) {
    const extra = categoryId ? `&category_id=${encodeURIComponent(categoryId)}` : '';
    return this._getOrThrow(this.api('get_live_streams', extra), []);
  }
  async getVodCategories() {
    return this._getOrThrow(this.api('get_vod_categories'), []);
  }
  async getVodStreams(categoryId) {
    const extra = categoryId ? `&category_id=${encodeURIComponent(categoryId)}` : '';
    return this._getOrThrow(this.api('get_vod_streams', extra), []);
  }
  async getVodInfo(vodId) {
    return this._getOrThrow(this.api('get_vod_info', `&vod_id=${vodId}`), null);
  }
  async getSeriesCategories() {
    return this._getOrThrow(this.api('get_series_categories'), []);
  }
  async getSeries(categoryId) {
    const extra = categoryId ? `&category_id=${encodeURIComponent(categoryId)}` : '';
    return this._getOrThrow(this.api('get_series', extra), []);
  }
  async getSeriesInfo(seriesId) {
    return this._getOrThrow(this.api('get_series_info', `&series_id=${seriesId}`), null);
  }

  liveStreamUrl(streamId, ext = 'm3u8') {
    return `${this.baseUrl}/live/${encodeURIComponent(this.username)}/${encodeURIComponent(this.password)}/${streamId}.${ext}`;
  }
  vodStreamUrl(streamId, ext = 'mp4') {
    return `${this.baseUrl}/movie/${encodeURIComponent(this.username)}/${encodeURIComponent(this.password)}/${streamId}.${ext}`;
  }
  seriesStreamUrl(episodeId, ext = 'mp4') {
    return `${this.baseUrl}/series/${encodeURIComponent(this.username)}/${encodeURIComponent(this.password)}/${episodeId}.${ext}`;
  }
}

// Basic M3U playlist parser -> normalized channel list
async function parseM3U(url) {
  const res = await window.api.getText(url);
  if (!res.ok) throw new Error('Could not download playlist');
  const lines = res.data.split(/\r?\n/);
  const items = [];
  let current = null;
  for (const line of lines) {
    if (line.startsWith('#EXTINF')) {
      const nameMatch = line.match(/,(.*)$/);
      const logoMatch = line.match(/tvg-logo="([^"]*)"/);
      const groupMatch = line.match(/group-title="([^"]*)"/);
      current = {
        name: nameMatch ? nameMatch[1].trim() : 'Unknown',
        logo: logoMatch ? logoMatch[1] : '',
        group: groupMatch ? groupMatch[1] : 'Uncategorized'
      };
    } else if (line && !line.startsWith('#') && current) {
      current.url = line.trim();
      items.push(current);
      current = null;
    }
  }
  return items;
}

window.XtreamClient = XtreamClient;
window.parseM3U = parseM3U;
