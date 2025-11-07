<?php
declare(strict_types=1);

init_headers();

$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
if ($method === 'OPTIONS') {
    http_response_code(204);
    exit;
}

$scriptDir = __DIR__;
$dbRelative = 'data' . DIRECTORY_SEPARATOR . 'games.db';
$dbPath = $scriptDir . DIRECTORY_SEPARATOR . $dbRelative;
$debugBase = [
    'scriptDir' => $scriptDir,
    'dbPath' => $dbPath,
    'dbPathSource' => 'scriptDir:' . str_replace('\\', '/', $dbRelative),
];

$db = null;

try {
    $db = open_database($dbPath);
    $gameId = trim((string) ($_GET['id'] ?? ''));

    if ($method === 'GET') {
        if ($gameId === '') {
            throw new HttpException(400, 'ID_REQUIRED', '缺少牌局 ID');
        }
        $state = fetch_game_state($db, $gameId);
        if ($state === null) {
            throw new HttpException(404, 'NOT_FOUND', '指定牌局不存在');
        }
        send_json(200, ['id' => $gameId, 'state' => $state]);
    } elseif ($method === 'POST') {
        $payload = read_json_body();
        $bodyState = isset($payload['state']) && is_array($payload['state']) ? $payload['state'] : null;
        $existing = null;
        if ($gameId !== '') {
            $existing = fetch_game_state($db, $gameId);
            if ($existing === null) {
                $gameId = '';
            }
        }

        if ($gameId !== '') {
            if ($bodyState === null) {
                throw new HttpException(400, 'STATE_REQUIRED', '缺少有效的 state 字段');
            }
            $updated = normalize_state_for_store($bodyState, $gameId, [
                'meta' => isset($existing['meta']) && is_array($existing['meta']) ? $existing['meta'] : [],
            ]);
            persist_game_state($db, $updated);
            send_json(200, ['id' => $gameId, 'state' => $updated]);
        } else {
            $initial = $bodyState ?? [];
            $newId = generate_game_id($db);
            $stored = normalize_state_for_store($initial, $newId);
            persist_game_state($db, $stored);
            send_json(201, ['id' => $newId, 'state' => $stored]);
        }
    } else {
        header('Allow: GET, POST, OPTIONS');
        throw new HttpException(405, 'METHOD_NOT_ALLOWED', '不支持的请求方法');
    }
} catch (\Throwable $error) {
    send_error($error, $debugBase);
} finally {
    if ($db instanceof \SQLite3) {
        $db->close();
    }
}

function init_headers(): void
{
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('Pragma: no-cache');
    header('Expires: 0');
    header('Access-Control-Allow-Origin: *');
    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type');
}

function open_database(string $path): \SQLite3
{
    if ($path === '' || !file_exists($path)) {
        throw new HttpException(500, 'DB_PATH_UNAVAILABLE', '无法定位数据库文件');
    }
    try {
        $db = new \SQLite3($path, SQLITE3_OPEN_READWRITE);
        $db->busyTimeout(1000);
        @$db->exec('PRAGMA journal_mode=WAL;');
        @$db->exec('PRAGMA synchronous=NORMAL;');
        return $db;
    } catch (\Throwable $error) {
        throw new HttpException(500, 'DB_CONNECTION_FAILED', '无法打开 SQLite 数据库', ['dbPath' => $path], $error);
    }
}

function fetch_game_state(\SQLite3 $db, string $id): ?array
{
    $sql = 'SELECT id,a_level,b_level,dealer,a1_fail_A,a1_fail_B,team_a_name,team_b_name,game_over,created_at,updated_at FROM games WHERE id = :id';
    $stmt = prepare_or_fail($db, $sql);
    $stmt->bindValue(':id', $id, SQLITE3_TEXT);
    $result = $stmt->execute();
    if ($result === false) {
        throw new HttpException(500, 'SQL_ERROR', '数据库操作失败', ['sql' => $sql]);
    }
    $row = $result->fetchArray(SQLITE3_ASSOC);
    $result->finalize();
    if (!$row) {
        return null;
    }
    return [
        'aLevel' => (int) ($row['a_level'] ?? 0),
        'bLevel' => (int) ($row['b_level'] ?? 0),
        'dealer' => normalize_dealer($row['dealer'] ?? null),
        'a1Fails' => [
            'A' => (int) ($row['a1_fail_A'] ?? 0),
            'B' => (int) ($row['a1_fail_B'] ?? 0),
        ],
        'teams' => [
            'A' => string_value($row['team_a_name'] ?? ''),
            'B' => string_value($row['team_b_name'] ?? ''),
        ],
        'gameOver' => ((int) ($row['game_over'] ?? 0)) !== 0,
        'history' => fetch_game_history($db, $id),
        'meta' => [
            'id' => string_value($row['id'] ?? ''),
            'createdAt' => string_value($row['created_at'] ?? ''),
            'updatedAt' => string_value($row['updated_at'] ?? ''),
        ],
    ];
}

function fetch_game_history(\SQLite3 $db, string $gameId): array
{
    $sql = 'SELECT winner,delta,pattern,notes,ts FROM game_history WHERE game_id = :id ORDER BY ts ASC, id ASC';
    $stmt = prepare_or_fail($db, $sql);
    $stmt->bindValue(':id', $gameId, SQLITE3_TEXT);
    $result = $stmt->execute();
    if ($result === false) {
        throw new HttpException(500, 'SQL_ERROR', '数据库操作失败', ['sql' => $sql]);
    }
    $items = [];
    while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
        $items[] = [
            'winner' => string_value($row['winner'] ?? ''),
            'delta' => (int) ($row['delta'] ?? 0),
            'pattern' => string_value($row['pattern'] ?? ''),
            'notes' => parse_history_notes($row['notes'] ?? ''),
            'ts' => (int) ($row['ts'] ?? 0),
        ];
    }
    $result->finalize();
    return $items;
}

function persist_game_state(\SQLite3 $db, array $state): void
{
    $meta = isset($state['meta']) && is_array($state['meta']) ? $state['meta'] : [];
    $id = trim((string) ($meta['id'] ?? ''));
    if ($id === '') {
        throw new HttpException(400, 'INVALID_STATE', 'state.meta.id 不可为空');
    }
    $dealer = normalize_dealer($state['dealer'] ?? null);
    $teams = normalize_teams($state['teams'] ?? []);
    $fails = normalize_a1_fails($state['a1Fails'] ?? []);
    $createdAt = string_value($meta['createdAt'] ?? '') ?: format_iso_date();
    $updatedAt = string_value($meta['updatedAt'] ?? '') ?: $createdAt;
    $history = ensure_array($state['history'] ?? []);

    $db->exec('BEGIN');
    try {
        $insertSql = 'INSERT OR REPLACE INTO games (id,a_level,b_level,dealer,a1_fail_A,a1_fail_B,team_a_name,team_b_name,game_over,created_at,updated_at) VALUES (:id,:aLevel,:bLevel,:dealer,:aFail,:bFail,:teamA,:teamB,:gameOver,:created,:updated)';
        $stmt = prepare_or_fail($db, $insertSql);
        $stmt->bindValue(':id', $id, SQLITE3_TEXT);
        $stmt->bindValue(':aLevel', (int) ($state['aLevel'] ?? 0), SQLITE3_INTEGER);
        $stmt->bindValue(':bLevel', (int) ($state['bLevel'] ?? 0), SQLITE3_INTEGER);
        if ($dealer === null) {
            $stmt->bindValue(':dealer', null, SQLITE3_NULL);
        } else {
            $stmt->bindValue(':dealer', $dealer, SQLITE3_TEXT);
        }
        $stmt->bindValue(':aFail', $fails['A'], SQLITE3_INTEGER);
        $stmt->bindValue(':bFail', $fails['B'], SQLITE3_INTEGER);
        $stmt->bindValue(':teamA', $teams['A'], SQLITE3_TEXT);
        $stmt->bindValue(':teamB', $teams['B'], SQLITE3_TEXT);
        $stmt->bindValue(':gameOver', !empty($state['gameOver']) ? 1 : 0, SQLITE3_INTEGER);
        $stmt->bindValue(':created', $createdAt, SQLITE3_TEXT);
        $stmt->bindValue(':updated', $updatedAt, SQLITE3_TEXT);
        if ($stmt->execute() === false) {
            throw new HttpException(500, 'SQL_ERROR', '数据库操作失败', ['sql' => $insertSql]);
        }

        $deleteSql = 'DELETE FROM game_history WHERE game_id = :id';
        $delete = prepare_or_fail($db, $deleteSql);
        $delete->bindValue(':id', $id, SQLITE3_TEXT);
        if ($delete->execute() === false) {
            throw new HttpException(500, 'SQL_ERROR', '数据库操作失败', ['sql' => $deleteSql]);
        }

        foreach ($history as $entry) {
            if (!is_array($entry)) {
                continue;
            }
            $notesJson = stringify_history_notes($entry['notes'] ?? []);
            $historySql = 'INSERT INTO game_history (game_id,winner,delta,pattern,notes,ts) VALUES (:gameId,:winner,:delta,:pattern,:notes,:ts)';
            $insert = prepare_or_fail($db, $historySql);
            $insert->bindValue(':gameId', $id, SQLITE3_TEXT);
            $insert->bindValue(':winner', string_value($entry['winner'] ?? ''), SQLITE3_TEXT);
            $insert->bindValue(':delta', (int) ($entry['delta'] ?? 0), SQLITE3_INTEGER);
            $insert->bindValue(':pattern', string_value($entry['pattern'] ?? ''), SQLITE3_TEXT);
            $insert->bindValue(':notes', $notesJson, SQLITE3_TEXT);
            $insert->bindValue(':ts', (int) ($entry['ts'] ?? (int) round(microtime(true) * 1000)), SQLITE3_INTEGER);
            if ($insert->execute() === false) {
                throw new HttpException(500, 'SQL_ERROR', '数据库操作失败', ['sql' => $historySql]);
            }
        }

        $db->exec('COMMIT');
    } catch (\Throwable $error) {
        @$db->exec('ROLLBACK');
        throw $error;
    }
}

function prepare_or_fail(\SQLite3 $db, string $sql): \SQLite3Stmt
{
    $stmt = $db->prepare($sql);
    if ($stmt === false) {
        throw new HttpException(500, 'SQL_ERROR', '数据库操作失败', ['sql' => $sql]);
    }
    return $stmt;
}

function normalize_state_for_store(array $state, string $id, array $defaults = []): array
{
    $metaDefaults = isset($defaults['meta']) && is_array($defaults['meta']) ? $defaults['meta'] : [];
    $incomingMeta = isset($state['meta']) && is_array($state['meta']) ? $state['meta'] : [];
    $meta = array_merge($metaDefaults, $incomingMeta);
    $nowIso = format_iso_date();
    if (empty($meta['createdAt'])) {
        $meta['createdAt'] = $nowIso;
    }
    $meta['updatedAt'] = $nowIso;
    $meta['id'] = $id;
    $state['meta'] = $meta;
    return $state;
}

function format_iso_date(?\DateTimeInterface $date = null): string
{
    $dt = $date ? \DateTimeImmutable::createFromInterface($date) : new \DateTimeImmutable('now', new \DateTimeZone('UTC'));
    return $dt->setTimezone(new \DateTimeZone('UTC'))->format('Y-m-d\TH:i:s.v\Z');
}

function generate_game_id(\SQLite3 $db): string
{
    $datePart = date('Ymd');
    $sql = 'SELECT MAX(id) AS max_id FROM games WHERE id LIKE :pattern';
    $stmt = prepare_or_fail($db, $sql);
    $stmt->bindValue(':pattern', $datePart . '____', SQLITE3_TEXT);
    $result = $stmt->execute();
    $maxSeq = 0;
    if ($result !== false) {
        $row = $result->fetchArray(SQLITE3_ASSOC);
        if ($row && isset($row['max_id'])) {
            $maxId = (string) $row['max_id'];
            if ($maxId !== '' && strpos($maxId, $datePart) === 0 && strlen($maxId) === strlen($datePart) + 4) {
                $seq = (int) substr($maxId, strlen($datePart));
                if ($seq > $maxSeq) {
                    $maxSeq = $seq;
                }
            }
        }
        $result->finalize();
    }
    $nextSeq = str_pad((string) ($maxSeq + 1), 4, '0', STR_PAD_LEFT);
    return $datePart . $nextSeq;
}

function ensure_array($value): array
{
    return is_array($value) ? $value : [];
}

function normalize_dealer($value): ?string
{
    $text = safe_trim($value);
    return $text === '' ? null : $text;
}

function normalize_teams($value): array
{
    $teams = ['A' => '', 'B' => ''];
    if (is_array($value)) {
        if (array_key_exists('A', $value)) {
            $teams['A'] = string_value($value['A']);
        }
        if (array_key_exists('B', $value)) {
            $teams['B'] = string_value($value['B']);
        }
    }
    return $teams;
}

function normalize_a1_fails($value): array
{
    $fails = ['A' => 0, 'B' => 0];
    if (is_array($value)) {
        if (array_key_exists('A', $value)) {
            $fails['A'] = (int) $value['A'];
        }
        if (array_key_exists('B', $value)) {
            $fails['B'] = (int) $value['B'];
        }
    }
    return $fails;
}

function string_value($value): string
{
    if (is_string($value) || is_numeric($value)) {
        return (string) $value;
    }
    return '';
}

function safe_trim($value): string
{
    if ($value === null) {
        return '';
    }
    $text = trim((string) $value);
    $lower = strtolower($text);
    if ($lower === 'null' || $lower === 'undefined') {
        return '';
    }
    return $text;
}

function parse_history_notes($value): array
{
    if ($value === null || $value === '') {
        return [];
    }
    $decoded = json_decode((string) $value, true);
    return is_array($decoded) ? $decoded : [];
}

function stringify_history_notes($value): string
{
    $notes = is_array($value) ? $value : [];
    $json = json_encode($notes, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    return $json === false ? '[]' : $json;
}

function read_json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || trim($raw) === '') {
        return [];
    }
    $decoded = json_decode($raw, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        throw new HttpException(400, 'INVALID_JSON', '无法解析传入的 JSON');
    }
    return is_array($decoded) ? $decoded : [];
}

function send_json(int $status, array $payload): void
{
    $body = $payload;
    $body['ok'] = true;
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function send_error(\Throwable $error, array $debugBase): void
{
    if ($error instanceof HttpException) {
        $status = $error->status();
        $payload = $error->payload();
    } else {
        $status = 500;
        $payload = [
            'error' => 'SERVER_ERROR',
            'message' => '服务器内部错误',
            'error_code' => 500,
            'error_msg' => '服务器内部错误',
        ];
    }

    if (!isset($payload['error_code'])) {
        $payload['error_code'] = $payload['error'] ?? 500;
    }
    if (!isset($payload['error_msg']) && !empty($payload['message'])) {
        $payload['error_msg'] = $payload['message'];
    }
    if (empty($payload['error'])) {
        $payload['error'] = 'SERVER_ERROR';
    }

    $payload['ok'] = false;
    $debug = isset($payload['debug']) && is_array($payload['debug']) ? $payload['debug'] : [];
    $payload['debug'] = array_merge($debugBase, $debug, build_debug_info($error));

    http_response_code($status);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/** @return array<string,mixed> */
function build_debug_info(?\Throwable $error): array
{
    if (!$error) {
        return [];
    }
    $info = [];
    $message = $error->getMessage();
    if ($message !== '') {
        $info['message'] = $message;
    }
    $info['number'] = $error->getCode();
    $info['file'] = $error->getFile();
    $info['lineNumber'] = $error->getLine();
    $info['stack'] = $error->getTraceAsString();
    if ($error->getPrevious()) {
        $info['innerMessage'] = $error->getPrevious()->getMessage();
        $info['innerNumber'] = $error->getPrevious()->getCode();
    }
    return $info;
}

final class HttpException extends \RuntimeException
{
    /** @var array<string,mixed> */
    private array $payload;
    private int $status;

    public function __construct(int $status, string $code, string $message = '', array $payload = [], ?\Throwable $previous = null)
    {
        $body = array_merge(['error' => $code], $payload);
        if ($message !== '' && !isset($body['message'])) {
            $body['message'] = $message;
        }
        parent::__construct($message !== '' ? $message : $code, $status, $previous);
        $this->status = $status;
        $this->payload = $body;
    }

    /** @return array<string,mixed> */
    public function payload(): array
    {
        return $this->payload;
    }

    public function status(): int
    {
        return $this->status;
    }
}
