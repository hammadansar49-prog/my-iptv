# Phase 1 — Audit of the TheOttDeals PC app (source of truth)

Everything below was read out of the Electron app in this repo (`main.js`, `preload.js`,
`src/xtream.js`, `src/player.js`, `src/mse.js`, `src/renderer.js`, `downloads.js`) plus the
locked-behaviour notes in `../CLAUDE.md`. Nothing here is invented. Where the PC app does **not**
implement something (notably EPG), it is called out explicitly under "Gaps / uncertainties" rather
than guessed at.

---

## 1. Backend surfaces

The app talks to **two completely separate backends**:

| Backend | Purpose | Auth |
| --- | --- | --- |
| The customer's **Xtream Codes** panel (`player_api.php`) | All content: live, VOD, series | username + password in the query string |
| **Firebase Realtime Database** REST API (`theottdeals-reviews-default-rtdb.firebaseio.com`) | License keys, plans, pricing, free trial, announcements, update check | none (unauthenticated, constrained by RTDB rules) |

There is no TheOttDeals-owned content API. The Xtream panel URL is entered by the user.

---

## 2. Xtream Codes API (`src/xtream.js`)

Base URL is normalised by stripping trailing slashes: `baseUrl.replace(/\/+$/, '')`.

Every metadata call is one GET:

```
{base}/player_api.php?username={u}&password={p}[&action={action}][&extra]
```

| Call | action | extra |
| --- | --- | --- |
| authenticate | *(none)* | — |
| live categories | `get_live_categories` | — |
| live streams | `get_live_streams` | `&category_id=` (optional) |
| VOD categories | `get_vod_categories` | — |
| VOD streams | `get_vod_streams` | `&category_id=` (optional) |
| VOD info | `get_vod_info` | `&vod_id={id}` |
| series categories | `get_series_categories` | — |
| series list | `get_series` | `&category_id=` (optional) |
| series info | `get_series_info` | `&series_id={id}` |

**Auth rules** (`authenticate()` in `src/xtream.js`) — must be reproduced exactly:

1. Response must contain `user_info`, else `Invalid response from server`.
2. `user_info.auth === 0` (number **or** string `'0'`) → `Invalid username or password`.
3. `user_info.status` present and `!== 'Active'` → `Account status: {status}`.
4. On success the whole `{ user_info, server_info }` object is returned and kept.

So the **valid subscription states come from `user_info.status`** (`Active` is the only accepted
one; others observed in Xtream panels: `Expired`, `Banned`, `Disabled`). `user_info` also carries
`exp_date` (unix seconds), `max_connections`, `active_cons`, `is_trial`. Do not invent states.

**Empty/missing-body tolerance**: `_getOrThrow` returns the fallback (`[]` / `null`) when the body
parses to `null`/`undefined` — a panel that answers `null` for an empty category must not be an
error. Transport failure *is* an error (`Could not reach the server`).

**Error mapping** the UI does (`friendlyAuthError`, `src/renderer.js`):

| Raw | Shown |
| --- | --- |
| `Server returned HTTP …` / `Invalid username or password` / `Invalid response from server` | "Invalid credentials — please check your Server URL, Username and Password and try again." |
| `ETIMEDOUT` / `timeout` | "Could not reach the server — check your internet connection, the server may be down." |
| `ENOTFOUND` / `getaddrinfo` | "Server address not found — please check the Server URL." |
| `ECONNREFUSED` | "Connection refused by the server." |

### Stream URLs

```
live    {base}/live/{user}/{pass}/{stream_id}.m3u8     (ext configurable, default m3u8)
movie   {base}/movie/{user}/{pass}/{stream_id}.{container_extension|mp4}
series  {base}/series/{user}/{pass}/{episode_id}.{container_extension|mp4}
```

`container_extension` comes from the VOD/episode object and **must** be used when present
(`src/renderer.js` lines ~2254, ~2271) — hardcoding `.mp4` breaks mkv content.

### Field names actually consumed

- live stream: `stream_id`, `name`, `stream_icon`, `category_id`, `epg_channel_id`
- VOD: `stream_id`, `name`, `stream_icon` / `cover`, `container_extension`, `category_id`,
  and from `get_vod_info`: `info.plot`, `info.movie_image`, `info.duration`, rating/year fields
- series: `series_id`, `name`, `cover`, `category_id`; `get_series_info` → `info.plot`,
  `episodes` keyed by season number, each episode `{ id, title, container_extension, info.movie_image, info.duration }`
- category: `category_id`, `category_name`

Artwork is passed through `usableArtwork()` (falls back across `stream_icon → cover → logo`) and a
resizing thumbnail proxy in the PC app. On Flutter the equivalent is a cached-network-image with a
`memCacheWidth` sized to the card, plus a placeholder/error fallback.

### HTTP client details worth copying

- Metadata fetches: `User-Agent: IPTVPlayer/1.0`, accepts gzip/deflate/br, follows up to 5
  redirects, **45 s** timeout, 80 MB response cap (`fetchText` in `main.js`).
- Downloads use a different UA: `VLC/3.0.21 Libavormat/61.19.100 Libavcodec/61.7.100` and
  `Accept-Encoding: identity` (`downloads.js`) — some panels behave differently per UA, keep it.
- An M3U playlist login mode also exists (`parseM3U`) reading `tvg-logo`, `group-title` and the
  name after the comma on `#EXTINF`. Second-class next to Xtream.

---

## 3. One connection at a time — the single most important constraint

`CLAUDE.md` locks this. The tested account is `max_connections=1`. `main.js` has
`providerHolders` / `holdProvider()` / `yieldProvider()` / `admitSession()` and every playback,
seek and download request carries a monotonically increasing session id (`player._sid(token)`).

Consequences the Flutter app **must** honour:

- Never hold two provider sockets at once — no "probe the stream then play it", no parallel range
  downloads, no prefetch of the next channel while one is playing.
- A download steps aside while something is playing (`pauseForPlayback`) and resumes ~2.5 s after
  playback ends (`playbackEnded`) — the delay exists because the panel has not yet noticed the old
  socket closed. A settings toggle (`setConcurrent`, default on in the PC app) lets downloads
  continue during playback for multi-connection accounts.
- When switching a live channel from a direct connection to the proxy, the PC app waits ~700 ms
  before opening the new connection, for the same reason. On Android the equivalent is: fully stop
  the old media before opening the new URL, with a short gap, rather than overlapping them.

### Live-channel reliability rules (from `src/player.js`, locked)

- **Fast fail**: a dead channel errors out in ~11–12 s, not 20–30 s. Achieved by a *single*
  attempt (no cascade of copy → audiofix → transcode) plus a hard read timeout (`-rw_timeout
  12000000`, i.e. 12 s) — without a read timeout a stalled TCP connection hangs forever with no
  error at all.
- **Freeze watchdog**: live only — if position stops advancing, nudge, then reload.
- **Audio watchdog**: AC-3/E-AC-3 can report as supported yet decode nothing, giving perfect
  picture and silence with *no error event*. Detected by zero decoded audio bytes after 4 s of real
  picture. On Android this class of problem is what `media_kit`/libmpv solves outright, which is
  why the player choice is not negotiable.
- Auto-retry: 3 retries with backoff, ~12 s stall timeout (duplicated in the old Flutter app's
  `player_screen.dart` and `live_tv_screen.dart`).

### VOD playback / seeking

PC plays VOD through `MseVodStreamer` (`src/mse.js`) rather than a plain `<video src>` so that
seeking into buffered data is instant, and a seek that must restart the stream lands exactly right
because the server reports the real media start (`X-Media-Start`). Resume-from-position is done by
passing `startAt` **into** the open call (`_playDirect`), *not* by seeking after playback starts.

Flutter equivalent: libmpv already gives instant in-buffer seeking, and resume must be applied as
`Player.open(Media(url, start: position))`, never as an `open()` followed by a `seek()`.

---

## 4. Session / accounts / favorites / history (all local)

All persisted through one blob: `store:get` / `store:set` (`main.js` `readStore`/`writeStore`,
`store.json`). Structure used by `src/renderer.js`:

```
store = {
  accounts: [ { id, type: 'xtream'|'m3u', name, url, username, password } ],   // most recent first
  activeAccountId,
  favorites: [ { key: "{section}:{id}", section, ... } ],
  history:   [ { key, type, title, subtitle, thumb, url, isLive,
                 resumeAt, duration, replay, updatedAt } ],
  settings:  { languagePicked, ... }
}
```

- **Session persistence = saved account + silent re-`authenticate()` on launch.** There is no
  token; the username/password are replayed on every start. On Android these belong in
  `flutter_secure_storage`, not plain prefs (spec §7/§51).
- Duplicate accounts are deduped on `(type, url, username)`.
- **Favorites** are local only (`favoritesList()`, key `{section}:{id}`). The backend does not sync
  them. Sections: live / movie / series.
- **History** (`upsertHistory`) keeps **60** entries max, most-recent-first, keyed by
  `historyKey` (live uses `live:{stream_id}`, VOD uses the stream URL). `resumeAt`/`duration` are
  forced to 0 for live. Writes are **throttled** during playback and flushed once on stop —
  the spec repeats this (§31). `replay` stores enough context to recreate playback (e.g. the
  series/episode).
- **Continue Watching** filter, reproduce exactly:
  `!isLive && duration > 0 && resumeAt > 5 && resumeAt < duration * 0.95`.

---

## 5. Downloads (`downloads.js`) — resume by byte offset

- **One download at a time.** Parallel ranges or parallel items get refused by the one-connection
  panel; they do not go faster.
- Data goes to `"<finalPath>.part"`, renamed on completion. On (re)start the existing `.part` size
  is `stat`ed and sent as `Range: bytes={have}-`.
  - `206` → append (`flags: 'a'`), and total size parsed out of `content-range`'s `/{total}`.
  - `200` → the server ignored the Range: `receivedBytes` resets to 0 and the file is truncated
    (`flags: 'w'`).
  - `416` with `have >= totalBytes` → already complete, finish.
- Retryable statuses: `401, 403, 408, 429, 458, 500, 502, 503, 504, 509`. Anything else fails hard.
- Retry backoff `min(15 s, 1000 * 2^(n-1))`, capped at **10** retries, then `failed`. Only the
  first error report per request counts (a dropped socket reports itself repeatedly).
- Socket timeout 30 s ("no data for 30 seconds"), up to 6 redirects.
- Free-space check before writing: fails with "Not enough disk space (X GB needed)".
- Speed is a smoothed EMA over 1 s windows (`prev*0.6 + instant*0.4`); ETA = remaining / speed.
  The 1 s ticker **stops itself** when nothing is active — do not leave a timer running (spec §47).
- Statuses: `queued | waiting | downloading | paused | completed | failed`. `waiting` means
  "yielded to playback"; anything `downloading`/`waiting` at shutdown is rewritten to `queued`.
- State is saved debounced (3 s) and immediately on any status change.
- File naming: sanitised, ≤140 chars; episodes go to `{dir}/{Series}/{Series} - S01E02 - Title.ext`.
- Downloaded files are played from disk, never re-streamed (`isDownloadedFile`, spec §29).

---

## 6. License / subscription (Firebase RTDB, unauthenticated REST)

Base: `https://theottdeals-reviews-default-rtdb.firebaseio.com` (overridable by env
`MYIPTV_RTDB_URL`). Requests are plain `GET`/`PUT`/`PATCH` on `{base}{path}.json`. These are
client-safe public config values; access control lives in the RTDB security rules.

Tree:

| Path | Contents |
| --- | --- |
| `/iptv/plans` | sellable plans (label, price, specs, enabled) |
| `/iptv/settings` | e.g. admin WhatsApp number |
| `/iptv/keys/{key}` | `{ status, plan_label, duration_days, activated_at, expires_at, max_devices, device_count, machine_ids: {id: true} }` |
| `/iptv/trial_config` | `{ enabled, duration_hours, specs }` |
| `/iptv/trials/{machineId}` | `{ claimed_at, expires_at }` — create-once per device |
| `/iptv/announcement`, `/iptv/announcement_reviews/{id}` | in-app announcement + ratings |
| `/iptv/update` | `{ version, download_url, notes, force_update }` |

**Key verification** (`verifyKeyAgainstRtdb`), exact order:

1. empty/missing row → `not-found`
2. `status === 'revoked'` → `revoked`
3. `status === 'unused'` → **activation**: PATCH `status:'active'`, `activated_at:now`,
   `expires_at: now + duration_days*86400000`, `device_count:1`, `machine_ids/{id}: true`
   → valid. *The expiry clock starts at first verify, not at generation.*
4. `expires_at < now` → `expired`
5. this `machineId` already in `machine_ids` → valid
6. else if `device_count >= max_devices` → `device-limit-reached`
7. else claim a slot (PATCH `device_count+1`, `machine_ids/{id}: true`) → valid

Reasons, complete set: `not-found | revoked | expired | device-limit-reached | network-error`.

`checkKeyStatusOnly` is a **read-only** variant used for frequent re-checks so a poll can never
consume a device slot. Flutter must use the same split.

**Recheck cadence**: background revalidate at most once per day, keeping the last known local state
when offline; renderer additionally polls every 30 min and bounces to the gate screen if invalid.
Plus a live SSE stream (`Accept: text/event-stream`) on the key's own node so a revocation lands
instantly. Trials skip all of this — `isTrial: true` has no `iptv/keys` row, its local `expiresAt`
is the whole story.

**Device identity**: `getMachineId()` = sha256 of `hostname|platform|arch|cpuModel|username|MAC`.
The MAC is in there deliberately so the value survives reinstall (the trial is one-per-device).
Android equivalent must likewise be install-stable; changing the formula re-binds every existing
key, so whatever is picked must be frozen from day one.

**Pricing must be instant, never "Loading…"**: `main.js` keeps `iptvLiveCache` populated at startup
and kept current by `subscribeRtdbSSE()` per path; the plans/settings/announcement/update handlers
read the cache synchronously. Flutter equivalent: prime the cache during splash, serve screens from
it, refresh in the background.

**Purchase path today** is manual: plans screen → "Get Package" → `https://wa.me/{number}?text=…`
prefilled with the plan name/price → admin arranges payment and mails a key back → user pastes it
into the gate. There is no in-app checkout. The PC app restricts its external-open IPC to
`wa.me`/`api.whatsapp.com` only.

**Android licensing does not exist yet** (CLAUDE.md: "Also not built: Android app licensing"). The
same RTDB tree is the right target, with an Android-stable machine id.

---

## 7. Gaps / uncertainties (flagged per spec §54 "STOP and identify uncertainties")

1. **EPG is not implemented in the PC app at all.** The only reference is a placeholder string:
   "Live broadcast — no program guide data from this provider." There is no `get_short_epg`,
   `get_simple_data_table` or XMLTV call anywhere. The spec (§11–13) makes EPG mandatory, so the
   Flutter app has to add it. Plan: use the standard Xtream endpoints on the same
   `player_api.php` base — `get_short_epg&stream_id={id}[&limit=n]` for the per-channel now/next
   two-row layout, `get_simple_data_table&stream_id={id}` for a fuller day view — with
   base64-decoded `title`/`description` and `start`/`end` timestamps, falling back cleanly to the
   PC app's "no guide data" state when the panel returns nothing. This is the one place the app
   goes beyond the PC app, and it is additive, not a replacement of existing behaviour.
2. **Server-side proxy/transcode does not exist on Android.** The PC app leans on a local ffmpeg
   proxy (`audiofix`, `transcode`) for codecs Chromium cannot decode. On Android the answer is
   libmpv (`media_kit`) decoding natively — same problem, different solution. The `audiofix`
   escalation therefore has no Android counterpart and must not be faked.
3. **No server-side favorites/history sync** exists. Local persistence only (spec §30 allows this).
4. **Xtream account `max_connections`** is returned by `authenticate()`; the PC app assumes 1. The
   Flutter app should read the real value and only allow concurrent download+playback when > 1.
5. **`container_extension` is sometimes absent** on episodes/VOD; fall back to `mp4` as PC does.

---

## 8. What this means for the Flutter build

| PC mechanism | Flutter counterpart |
| --- | --- |
| `fetchText` IPC proxy (CORS workaround) | plain `dio`/`http` — no proxy needed, but keep UA, timeouts, redirect and size caps |
| `providerHolders` / `admitSession` | a single `ConnectionGuard` all playback + download requests pass through |
| `MseVodStreamer` + `startAt` | `media_kit` `Player.open(Media(url, start:))` |
| `_armFreezeWatchdog` / retry x3 | one shared live-stream watchdog service, live only |
| ffmpeg `audiofix` | not needed — libmpv decodes AC-3/E-AC-3 |
| `downloads.js` | isolate/background download service, same `.part` + `Range` + backoff rules |
| `store.json` | `flutter_secure_storage` for credentials, a local DB/prefs for favorites/history/downloads |
| `iptvLiveCache` + SSE | prime at splash, SSE (or polling) refresh, screens read cache synchronously |
| `getMachineId()` | install-stable Android device id, frozen once chosen |

Player choice is settled and not to be revisited without real-device evidence (CLAUDE.md):
**`media_kit` (libmpv)**, not `video_player`/ExoPlayer, because it decodes MKV/HEVC/AC-3 that
Android's own decoders reject; `hwdec: 'no'` because hardware decode produced a black frame with
audio on a real device. `media_kit_video` was pinned to 1.2.5 historically because 1.3.0+ needs a
Flutter engine with `SurfaceProducer.Callback`; the toolchain here is **Flutter 3.41.9 / Dart
3.11.5**, which is far newer than that threshold, so the pin is lifted deliberately and noted here
rather than silently.
