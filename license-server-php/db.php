<?php
// Plain JSON-file store — same approach as license-server/db.js (the Node
// version this was ported from) and the main Electron app's own store.
// Avoids needing a MySQL database to be set up on the hosting account.

define('DB_FILE', __DIR__ . '/licenses.json');

function db_load() {
    if (!file_exists(DB_FILE)) {
        return [
            'nextKeyId' => 1,
            'nextPlanId' => 1,
            'keys' => [],
            'plans' => [],
            'settings' => ['whatsappNumber' => DEFAULT_WHATSAPP_NUMBER]
        ];
    }
    $raw = file_get_contents(DB_FILE);
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        return [
            'nextKeyId' => 1,
            'nextPlanId' => 1,
            'keys' => [],
            'plans' => [],
            'settings' => ['whatsappNumber' => DEFAULT_WHATSAPP_NUMBER]
        ];
    }
    if (!isset($data['settings'])) {
        $data['settings'] = ['whatsappNumber' => DEFAULT_WHATSAPP_NUMBER];
    }
    return $data;
}

function db_save($data) {
    $fp = fopen(DB_FILE, 'c+');
    flock($fp, LOCK_EX);
    ftruncate($fp, 0);
    fwrite($fp, json_encode($data, JSON_PRETTY_PRINT));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
}

function db_seed_defaults_if_empty() {
    $data = db_load();
    if (count($data['plans']) === 0) {
        $defaults = [
            ['1 Day', 1, 50, 'PKR'],
            ['1 Week', 7, 250, 'PKR'],
            ['2 Weeks', 14, 450, 'PKR'],
            ['1 Month', 30, 800, 'PKR'],
            ['3 Months', 90, 2200, 'PKR'],
            ['6 Months', 180, 4000, 'PKR'],
            ['12 Months', 360, 7000, 'PKR'],
        ];
        foreach ($defaults as $i => $d) {
            $data['plans'][] = [
                'id' => $data['nextPlanId']++,
                'label' => $d[0],
                'duration_days' => $d[1],
                'price' => $d[2],
                'currency' => $d[3],
                'sort_order' => $i,
                'enabled' => 1,
            ];
        }
        db_save($data);
    }
}
db_seed_defaults_if_empty();

function db_generate_key() {
    $part = function () {
        return strtoupper(bin2hex(random_bytes(3)));
    };
    return 'MYIPTV-' . $part() . '-' . $part() . '-' . $part();
}

function db_insert_key($key, $duration_days, $plan_label) {
    $data = db_load();
    $row = [
        'id' => $data['nextKeyId']++,
        'key' => $key,
        'duration_days' => $duration_days,
        'plan_label' => $plan_label,
        'status' => 'unused',
        'machine_id' => null,
        'created_at' => (int) round(microtime(true) * 1000),
        'activated_at' => null,
        'expires_at' => null,
    ];
    $data['keys'][] = $row;
    db_save($data);
    return $row;
}

function db_find_key_by_value($key) {
    $data = db_load();
    foreach ($data['keys'] as $row) {
        if ($row['key'] === $key) return $row;
    }
    return null;
}

function db_list_keys() {
    $data = db_load();
    $keys = $data['keys'];
    usort($keys, fn($a, $b) => $b['id'] <=> $a['id']);
    return $keys;
}

function db_activate_key($id, $machine_id, $activated_at, $expires_at) {
    $data = db_load();
    foreach ($data['keys'] as &$row) {
        if ($row['id'] === $id) {
            $row['status'] = 'active';
            $row['machine_id'] = $machine_id;
            $row['activated_at'] = $activated_at;
            $row['expires_at'] = $expires_at;
            db_save($data);
            return $row;
        }
    }
    return null;
}

function db_revoke_key($id) {
    $data = db_load();
    foreach ($data['keys'] as &$row) {
        if ($row['id'] === $id) {
            $row['status'] = 'revoked';
            db_save($data);
            return $row;
        }
    }
    return null;
}

function db_list_plans($enabled_only = false) {
    $data = db_load();
    $plans = $data['plans'];
    if ($enabled_only) {
        $plans = array_values(array_filter($plans, fn($p) => $p['enabled']));
    }
    usort($plans, fn($a, $b) => ($a['sort_order'] <=> $b['sort_order']) ?: ($a['duration_days'] <=> $b['duration_days']));
    return $plans;
}

function db_insert_plan($label, $duration_days, $price, $currency, $sort_order) {
    $data = db_load();
    $row = [
        'id' => $data['nextPlanId']++,
        'label' => $label,
        'duration_days' => $duration_days,
        'price' => $price,
        'currency' => $currency ?: 'PKR',
        'sort_order' => $sort_order ?: 0,
        'enabled' => 1,
    ];
    $data['plans'][] = $row;
    db_save($data);
    return $row;
}

function db_find_plan($id) {
    $data = db_load();
    foreach ($data['plans'] as $row) {
        if ($row['id'] === $id) return $row;
    }
    return null;
}

function db_update_plan($id, $patch) {
    $data = db_load();
    foreach ($data['plans'] as &$row) {
        if ($row['id'] === $id) {
            $row = array_merge($row, $patch);
            db_save($data);
            return $row;
        }
    }
    return null;
}

function db_delete_plan($id) {
    $data = db_load();
    $before = count($data['plans']);
    $data['plans'] = array_values(array_filter($data['plans'], fn($p) => $p['id'] !== $id));
    db_save($data);
    return count($data['plans']) < $before;
}

function db_get_settings() {
    $data = db_load();
    return $data['settings'];
}

function db_update_settings($patch) {
    $data = db_load();
    $data['settings'] = array_merge($data['settings'], $patch);
    db_save($data);
    return $data['settings'];
}
