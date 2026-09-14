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
- **Live TV** (`live_tv_screen.dart`) plays inline (YouTube-style: video on top, channel list
  below, same `Player` instance reused when switching channels — no reload) with a separate
  fullscreen/landscape mode toggled in place, not a route change. Home tab, EPG tab, and Favorites
  all route live taps through this screen, not straight into `player_screen.dart`.
- Same live-channel auto-retry logic as the PC app (3 retries with backoff, ~12s stall timeout)
  is duplicated in both `player_screen.dart` and `live_tv_screen.dart` — keep them in sync if one
  changes.

## Before pushing changes to GitHub
This repo has `node_modules/`, `release/`, `vendor/` (bundled ffmpeg) and `*.log` gitignored — they
should never show up in `git status` as untracked-and-about-to-be-added. If they do, something
changed the `.gitignore` or added a nested one; fix that before committing, don't just `git add -A`
through it.
