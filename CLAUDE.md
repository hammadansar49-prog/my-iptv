# Notes for whoever (human or AI) touches this repo next

The user has explicitly asked that the working behaviour below be treated as **locked**: a future
session (including a different AI) must not "simplify," "refactor," or otherwise change the
mechanisms described here without a real reason tied to a reported bug. Every one of these was
broken at least once and fixed only after real testing (playing actual streams, reading actual
server logs) — not by reasoning about the code alone. If something here is reported broken again,
re-read the relevant section below before touching the code; the fix is very likely already
described here and just needs to be restored, not reinvented.

## PC app (Electron) — `main.js`, `src/player.js`, `src/mse.js`, `src/renderer.js`

### One provider connection at a time
The Xtream account this app is tested against allows exactly **one simultaneous connection**
(`max_connections=1`). `main.js` has a whole subsystem for this: `providerHolders`,
`holdProvider()`, `yieldProvider()`, `admitSession()`, `suspendVodDownload`/`resumeVodDownload`,
and every playback/seek/download request is tagged with a growing `sid` from the window
(`player._sid(token)` in `src/player.js`). **Do not** add a code path that opens a second
connection to the provider (a probe, a download, a seek) without going through this system — that
is exactly what caused seeks to hang on "connecting" and live channels to buffer/retry
constantly, which took a full session to diagnose and fix.

### Live channel playback (`src/player.js`, `_playHls`/`_playMpegts`/`_playProxy`)
- **Fast-fail for dead channels**: a channel that never connects gets ~11-12s total before
  showing a clear error, not the 20-30s+ cascade it used to be. This relies on: a single proxy
  attempt for live (no cascading through copy→audiofix→transcode — see `_onVideoError`'s comment
  about why cascading is pointless when the source itself won't open), and `-rw_timeout 12000000`
  on the live ffmpeg args in `main.js` (without it, ffmpeg can hang forever on a stalled TCP
  connection with no error at all).
- **Freeze watchdog** (`_armFreezeWatchdog`): live streams that stop advancing get nudged, then
  reloaded. Only applies to live (`if (!this.isLive) return;`).
- **Audio watchdog** (`_armAudioWatchdog`): some channels' audio codec (commonly AC-3/E-AC-3)
  passes `MediaSource.isTypeSupported()` on this Chromium build yet never actually decodes —
  the picture plays perfectly and the channel is just silent, with **no error event at all**.
  This is told apart from "genuinely no audio in the source" by watching
  `video.webkitAudioDecodedByteCount`: zero bytes decoded after 4s of real picture triggers one
  switch to server-side `audiofix` (re-encode audio to AAC); if it's *still* zero after that, the
  source has no audio track at all (confirmed via `ffprobe` for e.g. "PK | ARY News") and the user
  is told via a toast (`_notify('no-audio', ...)`), not shown an error overlay — the video is fine.
- When switching from the direct HLS/mpegts connection to the proxy, there's a deliberate ~700ms
  delay before opening the new provider connection — asking immediately can get refused because
  the one-connection account hasn't yet noticed the old connection closed.

### Buffered-range bar (`src/renderer.js`, `updateBuffered`)
See the large comment directly above `updateBuffered`. Short version: `video.buffered` under
MediaSource reports many tiny near-touching ranges instead of one span; this function merges
ranges within `max(1.5s, duration*0.5%)` before drawing. **Do not remove the merge step** —
that's what makes the bar one solid line instead of a strip of slivers, and it's been "simplified"
back to broken twice already. Full story: project memory `buffered-range-locked`.

### VOD playback — MediaSource (`src/mse.js`) and instant seeking
VOD (movies/episodes) plays through `MseVodStreamer` (`src/mse.js`), not a plain `<video src>`.
This is what makes seeking to an already-buffered point instant (no reload) and lets the server
report a real running time via `X-Media-Start` (see `startProbeOutput`/`startHeadWriter` in
`main.js`) so a seek that has to restart the stream places the picture at the exact right moment
instead of a few seconds early/late. Resume-from-saved-position works by passing `startAt` straight
into `player.play()` (see `_playDirect`), not by seeking after the fact.

### Downloads (`downloads.js`, wired into `main.js` and `src/renderer.js`)
One download at a time (same one-connection reasoning as above). A download can run **while**
something else streams from the provider only if the toggle in Settings → Downloads is on (default
on) — see `setConcurrent`/`downloadWhileWatchingActive()`. Files resume from `<name>.part` by byte
offset; don't change that to "just restart the download" on failure — that defeats the point on a
slow/unstable connection.

## Android app (Flutter, `android_app/`)

- **Player**: `media_kit` (libmpv), not `video_player`/ExoPlayer — this is what lets it decode
  MKV/HEVC/AC-3 that Android's own decoders reject outright. `media_kit_video` is **pinned to
  1.2.5** in `pubspec.yaml`; 1.3.0+ uses an Android embedding API (`SurfaceProducer.Callback`)
  that requires a newer Flutter engine than may be installed — check the Flutter version before
  bumping this dependency, or the release build fails to compile with a cryptic Java error.
- `VideoControllerConfiguration(hwdec: 'no')` in `player_screen.dart` forces software video
  decoding. This was added because hardware decoding produced a black frame with audio still
  playing on a real test device (not just an emulator) — a known media_kit/Android issue. Don't
  remove it without confirming hardware decode actually renders on real hardware first.
- **Android TV decoding**: TV only (`PlayerController.tvMode`, set from `isTvProvider`) uses
  `hwdec: 'mediacodec-copy'` + `enableHardwareAcceleration: true` — the box's CPU could not
  software-decode/draw live streams (video juddered, audio fine). Phones keep `hwdec: 'no'`. If a TV
  shows a black picture with sound, revert the TV branch first.
- **Resume (Android)** does NOT use `Media(start:)`: on the real panel, opening at an offset made
  mpv treat the movie as an unseekable stream with no duration that played from 0:00 (reproduced
  on-device). `PlayerController` opens normally and seeks to `_pendingStart` once the duration is
  known, hiding the early positions so they never overwrite the Continue Watching point.
- **Live TV** (`live_tv_screen.dart`) plays inline (YouTube-style: video on top, channel list
  below, same `Player` instance reused when switching channels — no reload) with a separate
  fullscreen/landscape mode toggled in place, not a route change. Home tab, EPG tab, and Favorites
  all route live taps through this screen, not straight into `player_screen.dart`.
- Same live-channel auto-retry logic as the PC app (3 retries with backoff, ~12s stall timeout)
  is duplicated in both `player_screen.dart` and `live_tv_screen.dart` — keep them in sync if one
  changes.
- **Impeller is disabled** (`android:name="io.flutter.embedding.android.EnableImpeller"
  value="false"` in `android/app/src/main/AndroidManifest.xml`). On a real Oppo/ColorOS Android 14
  handset the app launched to a permanent black screen — no crash, no error, `adb logcat` showing
  the engine boot fine but then `FlutterRenderer: Width is zero. 0,0` repeatedly and both the
  Vulkan *and* GLES Impeller backends logging their own init (a fallback that itself never
  recovered). Skia (Impeller off) renders correctly on the same device. This is the same class of
  problem as the `hwdec: 'no'` note above — a rendering backend that is fine on an emulator/some
  devices and silently broken on a real one — so don't re-enable Impeller without testing on real
  hardware (ideally more than one device/GPU) first.
- **Admin-panel wiring (license / announcement / update)**, the Android twin of `iptvLiveCache` +
  `startLicenseStream`: `lib/data/api/rtdb_stream.dart` (`RtdbStream`) is the SSE client
  (`Accept: text/event-stream`, applies `put`/`patch` to a local copy so there's no re-GET, backoff
  reconnect, 75s keep-alive watchdog, forced reconnect on app resume).
  `lib/presentation/iptv_live/iptv_live_controller.dart` (`iptvLiveProvider`) streams
  `iptv/announcement`, `iptv/update`, `iptv/settings` from app start and `iptv/keys/<storedKey>`
  whenever `LicenseRepositoryImpl.changes` says a key is stored (trials: local `expiresAt` timer
  only). A revoked/deleted/non-`active`/expired key → `PlayerController.stopActive()`,
  `DownloadManager.pauseAll()`, pop `/player`/`/live`, and a blocking "Subscription ended" screen
  (WhatsApp from `iptv/settings.whatsappNumber`) that lifts live if the admin restores/extends.
  `lib/presentation/iptv_live/iptv_live_layer.dart` renders everything from `MaterialApp.router`'s
  `builder` (above the Navigator, so it covers the fullscreen player). Announcements show once per
  `created_at` (LocalStore `lastSeenAnnouncementAt`); feedback goes to
  `iptv/announcement_reviews/<ms>_<8hex>` in the PC app's exact shape. Updates apply only when
  `platform` is `android`/`all` (missing = pc); Profile → "Check Updates" does a fresh GET.
- **Licence gate / badge / plans** (`lib/presentation/license/`): `CatalogLoadingScreen._continue`
  (every login/restore/account-switch passes through it) routes to `/license` when
  `licenseStatusProvider` (stored licence + `iptvLiveProvider` key stream) is not active. Home
  header shows `LicenseBadge` (yellow FREE TRIAL countdown / red PRO days-left) → `/plans`. Plan
  "Activate Plan" first reads `iptv/keys/<KEY>` and rejects a key whose `duration_days` differs.
- **Announcement notifications while closed/backgrounded**: native Kotlin, no Dart in the
  background (`AnnouncementNotifier.kt`). `AnnouncementWorker` (WorkManager, 15 min, network
  constraint, scheduled from `MainActivity.onCreate` with KEEP) GETs `iptv/announcement.json`;
  `AnnouncementPushReceiver` handles FCM data messages. Both notify only if `created_at` >
  Dart LocalStore `lastSeenAnnouncementAt` (read from `filesDir/store.json`) AND > native
  `lastNotifiedAnnouncementAt`, and never while the activity is resumed. Tap → extra on the
  singleTop MainActivity → `theottdeals/announcements` `takePendingTap` → controller forces the
  popup even if already seen. FCM (`lib/services/notifications/announcement_push.dart`, topic
  `iptv_announcements`) is optional: google-services plugin applies only if
  `android/app/google-services.json` exists; Cloud Function + setup in `firebase/`.

## License key system (gate screen in the PC app, backed by theottdeals' own Firebase)

The PC app is gated behind a license key so it can be sold as a subscription.

**Current architecture (live)**: no separate license server at all — `main.js` talks directly to
the **same Firebase Realtime Database the theottdeals.com admin panel already uses**
(`https://theottdeals-reviews-default-rtdb.firebaseio.com`, project `theottdeals-reviews`), under a
new `iptv/` tree (`iptv/plans`, `iptv/settings`, `iptv/keys`). The admin panel for generating keys
and editing plans/pricing/WhatsApp number lives **inside theottdeals' own admin panel**
(`theottdeals` repo, `notadmin.html` + `assets/js/pages/admin-iptv.js`, a "MY IPTV" sidebar
button/modal added the same way every other feature there is built — see `admin-whatsapp.js` for
the pattern it copies) — not a separate URL to remember or maintain.

- `main.js`: `IPTV_RTDB_URL` (env var `MYIPTV_RTDB_URL`, defaults to the theottdeals RTDB URL
  above) + `rtdbRequest(method, path, body)` — plain HTTPS GET/PUT against RTDB's REST API
  (`<url>/<path>.json`), no Firebase SDK/credentials needed since these are public client-safe
  config values (same ones theottdeals' own `firebase-config.js` ships to browsers). `verifyKeyAgainstRtdb()`
  reads a key doc by its key-string-as-path-id, and if unused, PUTs back the same doc with
  `status: 'active'` — this exact transition (and nothing else) is what
  `database.rules.json`'s `iptv/keys/$keyId` rule allows from an unauthenticated caller; admin
  (logged into the theottdeals panel) can read/write anything under `iptv/`.
- **The RTDB rule enabling this is not yet applied** — a security-rules change needs the user's own
  review before going live (Claude Code's own safety classifier also blocks editing it
  automatically). The exact JSON to add to `database.rules.json` under `"rules"` is documented in
  the session that built this; ask the user if it's missing, or check whether `iptv/keys/$keyId`
  already exists in the deployed rules via the Firebase console before assuming it's live.
- `license-server/` (Node/Express) and `license-server-php/` (PHP, Hostinger-targeted) are
  **earlier iterations, superseded and unused** — kept in the repo for reference only. Don't extend
  either; extend the RTDB path in `main.js` and the `admin-iptv.js` module in the theottdeals repo
  instead. (Their existence was itself a pivot: Node needed hosting the user didn't have without a
  card, PHP worked on the user's existing Hostinger plan but still meant a second admin panel to
  maintain — RTDB direct removes both problems by reusing infra that already existed.)

**PC app integration** (`main.js`, `preload.js`, `src/index.html`, `src/renderer.js`,
`src/styles.css`): a `view-license` screen (same `showView()` pattern as every other screen) blocks
`boot()` from running at all until `license:getStatus` reports a valid, unexpired key.

**Pricing is live and instant, not hardcoded, no "Loading..." wait**: `main.js` keeps an in-memory
cache (`iptvLiveCache`) of plans/settings/trial-config/announcement/update, populated at app
startup and kept current for the rest of the session by `subscribeRtdbSSE()` — a live connection to
RTDB's REST API (`Accept: text/event-stream`) per path, the same trick `startLicenseStream` already
used for per-key revocation. `license:getPlans`/`license:getSettings`/`announcement:get`/
`update:check` all just read this cache synchronously now — no network round trip on the request
itself, which is what removed the "Loading plans..." flash on the plans screen. `armIptvLiveUpdates()`
in `src/renderer.js` re-renders the plans screen (if it's the one currently open) the instant
`main.js` pushes a cache-changed event, so an admin edit shows up while the screen is still open,
not just next time it's opened. Don't hardcode plan pricing back into `index.html`/`renderer.js`,
and don't reintroduce a direct `rtdbRequest` call inside these four IPC handlers — extend
`iptvLiveCache`/`subscribeRtdbSSE` instead, or the "instant, no loading" property breaks again.

**Key lifecycle**: a key's expiry clock starts on first successful `verify` call (not at
generation) — unsold keys don't expire sitting in inventory. Once activated, a key is bound to the
device's `machineId` (`getMachineId()` in `main.js`, a hash of hostname/platform/arch/username) and
rejects verification from a different device. `main.js`'s `revalidateLicenseInBackground()` re-
checks at most once per day (non-blocking, keeps the last known local state if offline) so a
revoked/expired key gets caught even if the app is never restarted; the renderer also polls
`license:getStatus` locally every 30 minutes (`armLicenseWatch()`) and bounces back to the gate
screen if it goes invalid.

**"See Plans" → WhatsApp flow**: on the license-gate screen, "See Plans" opens `view-plans`
(`renderPlansScreen()` in `src/renderer.js`), listing every enabled plan with a "Get Package"
button. Clicking it calls `openPackageOnWhatsApp(plan)`, which fetches the admin-set WhatsApp
number (`license:getSettings` → RTDB `iptv/settings`) and opens
`https://wa.me/<number>?text=<prefilled message>` via `shell.openExternal` in the main process
(`ipcMain.handle('shell:openExternal', ...)` in `main.js` — deliberately restricted to
`wa.me`/`api.whatsapp.com` URLs only, since it's callable from the renderer). The number and every
plan are editable live from the theottdeals admin panel and take effect immediately — the app
always fetches fresh, nothing is cached across a screen visit.

This is the actual purchase path today: customer picks a plan → WhatsApp opens with a message
naming the exact plan/price → admin arranges payment manually → admin generates a key in the
theottdeals admin panel and sends it back → customer pastes it into the license-gate screen, which
unlocks the app straight into its normal login flow (existing `boot()` call). Actual in-app
payment/checkout is still not built — this WhatsApp handoff is the whole "purchase" step for now.
Also not built: Android app licensing.

**Free trial (admin-configurable duration/on-off, one per device)**: a "Get Free Trial" button on
the plans screen (`renderPlansScreen()` in `src/renderer.js`) calls `trial:claim` (`main.js`). The
duration (default 24h), whether it's offered at all, and its specs/description text are set from
the theottdeals admin panel's "Free Trial" section (`admin-iptv.js`, `iptv/trial_config` in RTDB —
`{enabled, duration_hours, specs}`); `getTrialConfig()` in `main.js` reads this before every
`trial:checkAvailability`/`trial:claim` call, so an admin change (turning it off, or changing
24h to 3 days) takes effect immediately, no rebuild. This is
**deliberately not** the same mechanism as a purchased key — there's no row in `iptv/keys` for it
at all. Instead, `iptv/trials/{machineId}` is a create-once record: the RTDB rule
(`iptv/trials/$machineId`, `.write: "auth != null || !data.exists()"`) lets the app write it
exactly once per device and never again, so deleting/reinstalling the app (which wipes
`store.json`, where the trial's expiry is cached locally) does **not** grant a second trial — the
server-side record is what's actually authoritative, keyed to `getMachineId()`, which now also
folds in a NIC's MAC address specifically because that (unlike anything the app stores) survives a
reinstall. A license object with `isTrial: true` skips the normal per-key RTDB recheck/SSE-stream
machinery entirely (there's no `iptv/keys` row to check) — its own fixed `expiresAt` from claim time
is the whole story locally, which is fine since a trial isn't meant to be extended or revoked.
**Note**: changing `getMachineId()`'s formula (as happened when the MAC address was added) changes
every existing key's device-binding too — anyone already activated will see `wrong-device` on their
next check. Don't touch that function casually.

## Before pushing changes to GitHub
This repo has `node_modules/`, `release/`, `vendor/` (bundled ffmpeg) and `*.log` gitignored — they
should never show up in `git status` as untracked-and-about-to-be-added. If they do, something
changed the `.gitignore` or added a nested one; fix that before committing, don't just `git add -A`
through it.
