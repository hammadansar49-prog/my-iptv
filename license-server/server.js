const crypto = require('crypto');
const path = require('path');
const express = require('express');
const db = require('./db');

const PORT = process.env.PORT || 4100;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'change-me';

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

function timingSafeEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function requireAdmin(req, res, next) {
  const header = req.get('authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token || !timingSafeEqual(token, ADMIN_PASSWORD)) {
    return res.status(401).json({ ok: false, error: 'Unauthorized' });
  }
  next();
}

function generateKey() {
  const part = () => crypto.randomBytes(3).toString('hex').toUpperCase();
  return `MYIPTV-${part()}-${part()}-${part()}`;
}

app.post('/admin/login', (req, res) => {
  const { password } = req.body || {};
  if (!password || !timingSafeEqual(password, ADMIN_PASSWORD)) {
    return res.status(401).json({ ok: false, error: 'Wrong password' });
  }
  res.json({ ok: true });
});

app.post('/admin/keys', requireAdmin, (req, res) => {
  const { durationDays, planLabel } = req.body || {};
  const days = Number(durationDays);
  if (!Number.isFinite(days) || days <= 0) {
    return res.status(400).json({ ok: false, error: 'Invalid durationDays' });
  }
  const key = generateKey();
  db.insertKey({ key, duration_days: days, plan_label: planLabel || `${days} day(s)` });
  res.json({ ok: true, key });
});

app.get('/admin/keys', requireAdmin, (_req, res) => {
  res.json({ ok: true, keys: db.listKeys() });
});

app.post('/admin/keys/:id/revoke', requireAdmin, (req, res) => {
  const row = db.revokeKey(Number(req.params.id));
  if (!row) return res.status(404).json({ ok: false, error: 'Not found' });
  res.json({ ok: true });
});

// ---- Plans (pricing shown in the app's license-gate screen) ----
// Public read so the app can show live pricing; writes require admin auth.
app.get('/plans', (_req, res) => {
  res.json({ ok: true, plans: db.listPlans({ enabledOnly: true }) });
});

app.get('/admin/plans', requireAdmin, (_req, res) => {
  res.json({ ok: true, plans: db.listPlans() });
});

app.post('/admin/plans', requireAdmin, (req, res) => {
  const { label, durationDays, price, currency, sortOrder } = req.body || {};
  const days = Number(durationDays);
  const amount = Number(price);
  if (!label || !Number.isFinite(days) || days <= 0 || !Number.isFinite(amount) || amount < 0) {
    return res.status(400).json({ ok: false, error: 'Invalid plan fields' });
  }
  const row = db.insertPlan({ label, duration_days: days, price: amount, currency, sort_order: Number(sortOrder) || 0 });
  res.json({ ok: true, id: row.id });
});

app.put('/admin/plans/:id', requireAdmin, (req, res) => {
  const existing = db.findPlan(req.params.id);
  if (!existing) return res.status(404).json({ ok: false, error: 'Not found' });
  const { label, durationDays, price, currency, sortOrder, enabled } = req.body || {};
  const patch = {};
  if (label !== undefined) patch.label = label;
  if (Number.isFinite(Number(durationDays))) patch.duration_days = Number(durationDays);
  if (Number.isFinite(Number(price))) patch.price = Number(price);
  if (currency !== undefined) patch.currency = currency;
  if (Number.isFinite(Number(sortOrder))) patch.sort_order = Number(sortOrder);
  if (enabled !== undefined) patch.enabled = enabled ? 1 : 0;
  db.updatePlan(req.params.id, patch);
  res.json({ ok: true });
});

app.delete('/admin/plans/:id', requireAdmin, (req, res) => {
  const ok = db.deletePlan(req.params.id);
  if (!ok) return res.status(404).json({ ok: false, error: 'Not found' });
  res.json({ ok: true });
});

// ---- Settings (WhatsApp number the "Get Package" button messages) ----
app.get('/settings', (_req, res) => {
  res.json({ ok: true, settings: db.getSettings() });
});

app.put('/admin/settings', requireAdmin, (req, res) => {
  const { whatsappNumber } = req.body || {};
  const settings = db.updateSettings({ whatsappNumber: whatsappNumber !== undefined ? String(whatsappNumber).trim() : db.getSettings().whatsappNumber });
  res.json({ ok: true, settings });
});

app.post('/verify', (req, res) => {
  const { key, machineId } = req.body || {};
  if (!key || !machineId) {
    return res.status(400).json({ valid: false, reason: 'missing-fields' });
  }
  const row = db.findKeyByValue(String(key).trim());
  if (!row) return res.json({ valid: false, reason: 'not-found' });
  if (row.status === 'revoked') return res.json({ valid: false, reason: 'revoked' });

  const now = Date.now();

  if (row.status === 'unused') {
    const expiresAt = now + row.duration_days * 24 * 60 * 60 * 1000;
    db.activateKey(row.id, { machine_id: machineId, activated_at: now, expires_at: expiresAt });
    return res.json({ valid: true, plan: row.plan_label, expiresAt });
  }

  if (row.machine_id !== machineId) {
    return res.json({ valid: false, reason: 'wrong-device' });
  }
  if (row.expires_at && row.expires_at < now) {
    return res.json({ valid: false, reason: 'expired' });
  }
  return res.json({ valid: true, plan: row.plan_label, expiresAt: row.expires_at });
});

app.listen(PORT, () => {
  console.log(`MY IPTV license server listening on port ${PORT}`);
});
