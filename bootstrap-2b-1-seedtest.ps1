# bootstrap-2b-1-seedtest.ps1
# PART 2b-1: writes ONLY tests/integration/seed.test.ts.
# PowerShell 5.1, ASCII only, idempotent.

$ErrorActionPreference = 'Stop'

function W {
    param([string]$Path, [string]$Content)
    $full = Join-Path $PSScriptRoot $Path
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, $Content, $enc)
    Write-Host ("wrote " + $full)
}

W 'tests\integration\seed.test.ts' @'
import { Client } from 'pg';
import {
  createTestDatabase,
  dropTestDatabase,
} from '../helpers/db';
import {
  T, TENANT_A, TENANT_B,
  resetData,
  seedTenant,
  seedEndpoints,
  seedEvents,
  seedSecrets,
  seedDeliveries,
} from '../helpers/seed';

let dbName: string;
let admin: Client;

beforeAll(async () => {
  const r = await createTestDatabase();
  dbName = r.name;
  admin = r.pool;
});

afterAll(async () => {
  if (dbName) {
    await dropTestDatabase(dbName);
  }
});

beforeEach(async () => {
  await resetData(admin);
});

test('1 seedTenant with explicit id, twice, no error, exactly one row', async () => {
  await seedTenant(admin, T);
  await seedTenant(admin, T);
  const r = await admin.query(
    'SELECT COUNT(*)::int AS n FROM tenants WHERE id = $1', [T]);
  expect(r.rows[0].n).toBe(1);
});

test('2 seedEndpoints with never-seeded tenantId: succeeds, tenant exists, options stored', async () => {
  const eps = await seedEndpoints(admin, {
    count: 3, tenantId: TENANT_A, enabled: false,
    url: 'https://custom.example/path',
  });
  expect(eps.length).toBe(3);
  const t = await admin.query(
    'SELECT 1 FROM tenants WHERE id = $1', [TENANT_A]);
  expect(t.rowCount).toBe(1);
  const rows = await admin.query(
    'SELECT enabled, url FROM endpoints WHERE tenant_id = $1', [TENANT_A]);
  expect(rows.rowCount).toBe(3);
  for (const r of rows.rows) {
    expect(r.enabled).toBe(false);
    expect(r.url).toBe('https://custom.example/path');
  }
});

test('3 seedEvents with never-seeded tenantId: succeeds; hash 1 byte; bytes {}', async () => {
  const evs = await seedEvents(admin, { count: 2, tenantId: TENANT_B });
  expect(evs.length).toBe(2);
  const t = await admin.query(
    'SELECT 1 FROM tenants WHERE id = $1', [TENANT_B]);
  expect(t.rowCount).toBe(1);
  const rows = await admin.query(
    'SELECT octet_length(payload_hash) AS h_len, payload_bytes FROM events WHERE tenant_id = $1',
    [TENANT_B]);
  expect(rows.rowCount).toBe(2);
  for (const r of rows.rows) {
    expect(r.h_len).toBe(1);
    expect(Buffer.compare(r.payload_bytes, Buffer.from('{}'))).toBe(0);
  }
});

test('4 seedSecrets for endpoint from seedEndpoints: count rows, tenant_id matches', async () => {
  const [ep] = await seedEndpoints(admin, { count: 1, tenantId: T });
  const secs = await seedSecrets(admin, {
    endpointId: ep.id, tenantId: T, count: 2,
  });
  expect(secs.length).toBe(2);
  const rows = await admin.query(
    'SELECT tenant_id FROM endpoint_secrets WHERE endpoint_id = $1', [ep.id]);
  expect(rows.rowCount).toBe(2);
  for (const r of rows.rows) {
    expect(r.tenant_id).toBe(T);
  }
});

test('5 seedDeliveries count 3 on never-seeded tenant: 3 rows, 3 events, 1 endpoint, defaults', async () => {
  const ds = await seedDeliveries(admin, { count: 3, tenantId: T });
  expect(ds.length).toBe(3);
  expect(new Set(ds.map(d => d.event_id)).size).toBe(3);
  expect(new Set(ds.map(d => d.endpoint_id)).size).toBe(1);
  const rows = await admin.query(
    `SELECT status, attempts, total_attempts, (next_attempt_at <= now()) AS due
       FROM deliveries WHERE tenant_id = $1`, [T]);
  expect(rows.rowCount).toBe(3);
  for (const r of rows.rows) {
    expect(r.status).toBe('pending');
    expect(r.attempts).toBe(0);
    expect(r.total_attempts).toBe(0);
    expect(r.due).toBe(true);
  }
});

test('6 seedDeliveries count 150 (generate_series): 150 deliveries, 150 events, defaults', async () => {
  const ds = await seedDeliveries(admin, { count: 150, tenantId: TENANT_A });
  expect(ds.length).toBe(150);
  expect(new Set(ds.map(d => d.event_id)).size).toBe(150);
  const ev = await admin.query(
    'SELECT COUNT(*)::int AS n FROM events WHERE tenant_id = $1', [TENANT_A]);
  expect(ev.rows[0].n).toBe(150);
  const rows = await admin.query(
    `SELECT status, attempts, total_attempts FROM deliveries WHERE tenant_id = $1`,
    [TENANT_A]);
  expect(rows.rowCount).toBe(150);
  for (const r of rows.rows) {
    expect(r.status).toBe('pending');
    expect(r.attempts).toBe(0);
    expect(r.total_attempts).toBe(0);
  }
});

async function checkOptions(count: number): Promise<void> {
  const tenantId = count >= 100 ? TENANT_A : T;
  const ds = await seedDeliveries(admin, {
    count, tenantId, status: 'processing',
    attempts: 9, totalAttempts: 9, maxAttempts: 8, reclaimCount: 2,
    lockedUntilOffsetSec: -1,
  });
  expect(ds.length).toBe(count);
  const rows = await admin.query(
    `SELECT status, attempts, total_attempts, max_attempts, reclaim_count,
            (locked_until < now()) AS locked_past
       FROM deliveries WHERE tenant_id = $1`, [tenantId]);
  expect(rows.rowCount).toBe(count);
  for (const r of rows.rows) {
    expect(r.status).toBe('processing');
    expect(r.attempts).toBe(9);
    expect(r.total_attempts).toBe(9);
    expect(r.max_attempts).toBe(8);
    expect(r.reclaim_count).toBe(2);
    expect(r.locked_past).toBe(true);
  }
}

test('7a option passthrough, count 3', async () => {
  await checkOptions(3);
});

test('7b option passthrough, count 150', async () => {
  await checkOptions(150);
});

async function checkOffsets(count: number): Promise<void> {
  const tenantId = count >= 100 ? TENANT_A : TENANT_B;
  await seedDeliveries(admin, { count, tenantId, nextAttemptOffsetSec: -3600 });
  const neg = await admin.query(
    `SELECT COUNT(*)::int AS n FROM deliveries
       WHERE tenant_id = $1 AND next_attempt_at < now() - interval '59 minutes'`,
    [tenantId]);
  expect(neg.rows[0].n).toBe(count);

  await admin.query('DELETE FROM deliveries WHERE tenant_id = $1', [tenantId]);

  await seedDeliveries(admin, { count, tenantId, nextAttemptOffsetSec: 3600 });
  const pos = await admin.query(
    `SELECT COUNT(*)::int AS n FROM deliveries
       WHERE tenant_id = $1 AND next_attempt_at > now() + interval '59 minutes'`,
    [tenantId]);
  expect(pos.rows[0].n).toBe(count);

  const nullLock = await admin.query(
    `SELECT COUNT(*)::int AS n FROM deliveries
       WHERE tenant_id = $1 AND locked_until IS NULL`, [tenantId]);
  expect(nullLock.rows[0].n).toBe(count);
}

test('8a offsets, count 3', async () => {
  await checkOffsets(3);
});

test('8b offsets, count 150', async () => {
  await checkOffsets(150);
});

test('9 totalAttempts defaults to attempts when omitted', async () => {
  await seedDeliveries(admin, { count: 2, tenantId: T, attempts: 5 });
  const rows = await admin.query(
    'SELECT total_attempts FROM deliveries WHERE tenant_id = $1', [T]);
  expect(rows.rowCount).toBe(2);
  for (const r of rows.rows) {
    expect(r.total_attempts).toBe(5);
  }
});

test('10 resetData truncates 8 data tables, leaves _migrations unchanged', async () => {
  const [ep] = await seedEndpoints(admin, { count: 1, tenantId: T });
  await seedSecrets(admin, { endpointId: ep.id, tenantId: T });
  await seedEvents(admin, { count: 1, tenantId: T });
  await seedDeliveries(admin, { count: 1, tenantId: T });
  await admin.query(
    `INSERT INTO delivery_attempts
       (delivery_id, attempt_number, lease_token, started_at, outcome)
     SELECT d.id, 1, gen_random_uuid(), now(), 'success' FROM deliveries d LIMIT 1`);
  const beforeMigr = await admin.query('SELECT COUNT(*)::int AS n FROM _migrations');
  await resetData(admin);
  const tables = ['delivery_attempts', 'deliveries', 'events', 'subscriptions',
                  'endpoint_secrets', 'endpoints', 'api_keys', 'tenants'];
  for (const t of tables) {
    const r = await admin.query('SELECT COUNT(*)::int AS n FROM ' + t);
    expect(r.rows[0].n).toBe(0);
  }
  const afterMigr = await admin.query('SELECT COUNT(*)::int AS n FROM _migrations');
  expect(afterMigr.rows[0].n).toBe(beforeMigr.rows[0].n);
});

test('11 two seedDeliveries calls sharing one endpointId: no unique violation', async () => {
  const [ep] = await seedEndpoints(admin, { count: 1, tenantId: T });
  await seedDeliveries(admin, { count: 1, tenantId: T, endpointId: ep.id });
  await seedDeliveries(admin, { count: 1, tenantId: T, endpointId: ep.id });
  const r = await admin.query(
    'SELECT COUNT(*)::int AS n FROM deliveries WHERE endpoint_id = $1', [ep.id]);
  expect(r.rows[0].n).toBe(2);
});

test('12 T, TENANT_A, TENANT_B pairwise distinct UUIDs', async () => {
  const re = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  expect(re.test(T)).toBe(true);
  expect(re.test(TENANT_A)).toBe(true);
  expect(re.test(TENANT_B)).toBe(true);
  expect(new Set([T, TENANT_A, TENANT_B]).size).toBe(3);
});
'@

Write-Host ''
Write-Host 'Next: run'
Write-Host '  npx jest seed'
Write-Host '  (must FAIL; predictions are in the reply text)'
Write-Host '  then run bootstrap-2b-2-seedfix.ps1'