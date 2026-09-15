<?php
require __DIR__ . '/config.php';
require __DIR__ . '/db.php';

header('Content-Type: application/json');

function json_body() {
    $raw = file_get_contents('php://input');
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

function require_admin() {
    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    $token = (strpos($header, 'Bearer ') === 0) ? substr($header, 7) : '';
    if (!$token || !hash_equals(ADMIN_PASSWORD, $token)) {
        http_response_code(401);
        echo json_encode(['ok' => false, 'error' => 'Unauthorized']);
        exit;
    }
}

$route = $_GET['r'] ?? '';
$method = $_SERVER['REQUEST_METHOD'];

switch (true) {

    // ---- public: pricing plans shown in the app's license-gate screen ----
    case $route === 'plans' && $method === 'GET':
        echo json_encode(['ok' => true, 'plans' => db_list_plans(true)]);
        break;

    // ---- public: WhatsApp number the "Get Package" button messages ----
    case $route === 'settings' && $method === 'GET':
        echo json_encode(['ok' => true, 'settings' => db_get_settings()]);
        break;

    // ---- public: called by the PC app to activate/check a key ----
    case $route === 'verify' && $method === 'POST':
        $body = json_body();
        $key = trim($body['key'] ?? '');
        $machineId = $body['machineId'] ?? '';
        if (!$key || !$machineId) {
            echo json_encode(['valid' => false, 'reason' => 'missing-fields']);
            break;
        }
        $row = db_find_key_by_value($key);
        if (!$row) { echo json_encode(['valid' => false, 'reason' => 'not-found']); break; }
        if ($row['status'] === 'revoked') { echo json_encode(['valid' => false, 'reason' => 'revoked']); break; }

        $now = (int) round(microtime(true) * 1000);

        if ($row['status'] === 'unused') {
            $expiresAt = $now + $row['duration_days'] * 24 * 60 * 60 * 1000;
            db_activate_key($row['id'], $machineId, $now, $expiresAt);
            echo json_encode(['valid' => true, 'plan' => $row['plan_label'], 'expiresAt' => $expiresAt]);
            break;
        }

        if ($row['machine_id'] !== $machineId) {
            echo json_encode(['valid' => false, 'reason' => 'wrong-device']);
            break;
        }
        if ($row['expires_at'] && $row['expires_at'] < $now) {
            echo json_encode(['valid' => false, 'reason' => 'expired']);
            break;
        }
        echo json_encode(['valid' => true, 'plan' => $row['plan_label'], 'expiresAt' => $row['expires_at']]);
        break;

    // ---- admin: login check ----
    case $route === 'admin/login' && $method === 'POST':
        $body = json_body();
        $password = $body['password'] ?? '';
        if (!$password || !hash_equals(ADMIN_PASSWORD, $password)) {
            http_response_code(401);
            echo json_encode(['ok' => false, 'error' => 'Wrong password']);
            break;
        }
        echo json_encode(['ok' => true]);
        break;

    // ---- admin: keys ----
    case $route === 'admin/keys' && $method === 'GET':
        require_admin();
        echo json_encode(['ok' => true, 'keys' => db_list_keys()]);
        break;

    case $route === 'admin/keys' && $method === 'POST':
        require_admin();
        $body = json_body();
        $days = floatval($body['durationDays'] ?? 0);
        if ($days <= 0) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'error' => 'Invalid durationDays']);
            break;
        }
        $planLabel = trim($body['planLabel'] ?? '') ?: ($days . ' day(s)');
        $key = db_generate_key();
        db_insert_key($key, $days, $planLabel);
        echo json_encode(['ok' => true, 'key' => $key]);
        break;

    case $route === 'admin/keys/revoke' && $method === 'POST':
        require_admin();
        $id = intval($_GET['id'] ?? 0);
        $row = db_revoke_key($id);
        if (!$row) { http_response_code(404); echo json_encode(['ok' => false, 'error' => 'Not found']); break; }
        echo json_encode(['ok' => true]);
        break;

    // ---- admin: plans ----
    case $route === 'admin/plans' && $method === 'GET':
        require_admin();
        echo json_encode(['ok' => true, 'plans' => db_list_plans(false)]);
        break;

    case $route === 'admin/plans' && $method === 'POST':
        require_admin();
        $body = json_body();
        $label = trim($body['label'] ?? '');
        $days = floatval($body['durationDays'] ?? 0);
        $price = floatval($body['price'] ?? -1);
        if (!$label || $days <= 0 || $price < 0) {
            http_response_code(400);
            echo json_encode(['ok' => false, 'error' => 'Invalid plan fields']);
            break;
        }
        $row = db_insert_plan($label, $days, $price, $body['currency'] ?? 'PKR', intval($body['sortOrder'] ?? 0));
        echo json_encode(['ok' => true, 'id' => $row['id']]);
        break;

    case $route === 'admin/plans/id' && $method === 'PUT':
        require_admin();
        $id = intval($_GET['id'] ?? 0);
        $existing = db_find_plan($id);
        if (!$existing) { http_response_code(404); echo json_encode(['ok' => false, 'error' => 'Not found']); break; }
        $body = json_body();
        $patch = [];
        if (isset($body['label'])) $patch['label'] = $body['label'];
        if (isset($body['durationDays'])) $patch['duration_days'] = floatval($body['durationDays']);
        if (isset($body['price'])) $patch['price'] = floatval($body['price']);
        if (isset($body['currency'])) $patch['currency'] = $body['currency'];
        if (isset($body['sortOrder'])) $patch['sort_order'] = intval($body['sortOrder']);
        if (isset($body['enabled'])) $patch['enabled'] = $body['enabled'] ? 1 : 0;
        db_update_plan($id, $patch);
        echo json_encode(['ok' => true]);
        break;

    case $route === 'admin/plans/id' && $method === 'DELETE':
        require_admin();
        $id = intval($_GET['id'] ?? 0);
        $ok = db_delete_plan($id);
        if (!$ok) { http_response_code(404); echo json_encode(['ok' => false, 'error' => 'Not found']); break; }
        echo json_encode(['ok' => true]);
        break;

    // ---- admin: settings ----
    case $route === 'admin/settings' && $method === 'PUT':
        require_admin();
        $body = json_body();
        $settings = db_update_settings([
            'whatsappNumber' => isset($body['whatsappNumber']) ? trim($body['whatsappNumber']) : db_get_settings()['whatsappNumber'],
        ]);
        echo json_encode(['ok' => true, 'settings' => $settings]);
        break;

    default:
        http_response_code(404);
        echo json_encode(['ok' => false, 'error' => 'Not found']);
}
