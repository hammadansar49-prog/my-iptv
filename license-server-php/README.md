# MY IPTV — License Server (PHP version)

Same license system as `license-server/` (the Node version), rewritten in plain PHP so it can run
directly on shared hosting (Hostinger) that doesn't support Node.js apps — no separate service,
no card, no extra account needed.

## Upload (Hostinger hPanel)

1. Open **hPanel → theottdeals.com → File manager** (or the "Open" button next to File manager on
   the site dashboard).
2. Inside `public_html`, create a new folder called `license`.
3. Upload every file from this folder (`config.php`, `db.php`, `index.php`, `.htaccess`,
   `admin.html`) into `public_html/license/`.
4. **Edit `config.php`** (right-click → Edit, or download/edit/re-upload) and change
   `define('ADMIN_PASSWORD', 'change-me');` to a real password. This is the password for the admin
   panel — remember it.
5. Visit `https://theottdeals.com/license/admin.html` in a browser, log in with that password. You
   should see the pricing plans table (pre-filled with defaults) and the WhatsApp number field
   (pre-filled with `923341100761`).

That's it — no build step, no npm install, no database setup. `licenses.json` (where keys/plans are
stored) is created automatically the first time it's needed.

## After uploading

Tell the PC app where this is by pointing `LICENSE_SERVER_URL` in `main.js` at
`https://theottdeals.com/license`, then rebuild the installer.

## API (same shape as the Node version, served via `index.php` + `.htaccess` rewrites)

- `GET /license/plans` — public, live pricing.
- `GET /license/settings` — public, WhatsApp number.
- `POST /license/verify` — called by the app.
- `POST /license/admin/login`, `GET/POST /license/admin/keys`,
  `POST /license/admin/keys/:id/revoke`, `GET/POST /license/admin/plans`,
  `PUT/DELETE /license/admin/plans/:id`, `PUT /license/admin/settings` — all admin-only
  (`Authorization: Bearer <ADMIN_PASSWORD>`).
