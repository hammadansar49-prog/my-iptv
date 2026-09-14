// Plain JSON-file store, same approach the main Electron app already uses
// for its own settings (see readStore/writeStore in main.js) — avoids a
// native module (better-sqlite3 needs a C++ build toolchain/Python that
// isn't guaranteed to be present wherever this gets deployed).
const fs = require('fs');
const path = require('path');

const DB_FILE = path.join(__dirname, 'licenses.json');

function load() {
  try {
    return JSON.parse(fs.readFileSync(DB_FILE, 'utf-8'));
  } catch {
    return { nextKeyId: 1, nextPlanId: 1, keys: [], plans: [] };
  }
}

function save(data) {
  fs.writeFileSync(DB_FILE, JSON.stringify(data, null, 2), 'utf-8');
}

let data = load();

// Seed a sensible default plan list the first time the store is created, so
// the admin panel and app aren't empty out of the box. Admin can edit/delete these.
if (data.plans.length === 0) {
  const defaults = [
    ['1 Day', 1, 50, 'PKR'],
    ['1 Week', 7, 250, 'PKR'],
    ['2 Weeks', 14, 450, 'PKR'],
    ['1 Month', 30, 800, 'PKR'],
    ['3 Months', 90, 2200, 'PKR'],
    ['6 Months', 180, 4000, 'PKR'],
    ['12 Months', 360, 7000, 'PKR']
  ];
  defaults.forEach(([label, duration_days, price, currency], i) => {
    data.plans.push({
      id: data.nextPlanId++,
      label, duration_days, price, currency,
      sort_order: i,
      enabled: 1
    });
  });
  save(data);
}

module.exports = {
  // ---- keys ----
  insertKey({ key, duration_days, plan_label }) {
    const row = {
      id: data.nextKeyId++,
      key, duration_days, plan_label,
      status: 'unused',
      machine_id: null,
      created_at: Date.now(),
      activated_at: null,
      expires_at: null
    };
    data.keys.push(row);
    save(data);
    return row;
  },
  findKeyByValue(key) {
    return data.keys.find((k) => k.key === key) || null;
  },
  listKeys() {
    return [...data.keys].sort((a, b) => b.id - a.id);
  },
  activateKey(id, { machine_id, activated_at, expires_at }) {
    const row = data.keys.find((k) => k.id === id);
    if (!row) return null;
    Object.assign(row, { status: 'active', machine_id, activated_at, expires_at });
    save(data);
    return row;
  },
  revokeKey(id) {
    const row = data.keys.find((k) => k.id === id);
    if (!row) return null;
    row.status = 'revoked';
    save(data);
    return row;
  },

  // ---- plans ----
  listPlans({ enabledOnly = false } = {}) {
    const rows = enabledOnly ? data.plans.filter((p) => p.enabled) : data.plans;
    return [...rows].sort((a, b) => (a.sort_order - b.sort_order) || (a.duration_days - b.duration_days));
  },
  insertPlan({ label, duration_days, price, currency, sort_order }) {
    const row = {
      id: data.nextPlanId++,
      label, duration_days, price,
      currency: currency || 'PKR',
      sort_order: sort_order || 0,
      enabled: 1
    };
    data.plans.push(row);
    save(data);
    return row;
  },
  findPlan(id) {
    return data.plans.find((p) => p.id === Number(id)) || null;
  },
  updatePlan(id, patch) {
    const row = data.plans.find((p) => p.id === Number(id));
    if (!row) return null;
    Object.assign(row, patch);
    save(data);
    return row;
  },
  deletePlan(id) {
    const before = data.plans.length;
    data.plans = data.plans.filter((p) => p.id !== Number(id));
    save(data);
    return data.plans.length < before;
  }
};
