# MY IPTV — License Server

Small standalone service that issues and verifies subscription keys for the MY IPTV PC app.
Not part of the Electron app itself — run it separately, anywhere reachable over the internet.

## Run locally

```bash
cd license-server
npm install
set ADMIN_PASSWORD=your-strong-password
set PORT=4100
npm start
```

Then open `http://localhost:4100/admin.html` in a browser to generate/manage keys.

## Deploy

Any Node host works (a VPS, Render, Railway, etc.). Set the environment variables:

- `ADMIN_PASSWORD` — password for the admin panel. **Change this from the default before deploying.**
- `PORT` — defaults to 4100.

The data file (`licenses.json`) is created automatically next to `server.js` — back it up if you
redeploy to a host with an ephemeral filesystem.

## After deploying

Update `LICENSE_SERVER_URL` in the main app's `main.js` to point at your deployed URL
(e.g. `https://your-domain.com`), then rebuild the PC app installer.

## API

- `POST /admin/login` `{password}` — check the admin password.
- `POST /admin/keys` `{durationDays, planLabel}` (needs `Authorization: Bearer <ADMIN_PASSWORD>`) — generate a key.
- `GET /admin/keys` (admin) — list all keys.
- `POST /admin/keys/:id/revoke` (admin) — revoke a key.
- `POST /verify` `{key, machineId}` — called by the app itself; activates an unused key on first
  call (expiry starts here), or checks an already-active key still belongs to the same device and
  hasn't expired.
