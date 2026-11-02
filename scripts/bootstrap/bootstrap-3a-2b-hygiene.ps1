# bootstrap-3a-2b-hygiene.ps1
# PART 3A, SCRIPT A2b: transaction leak fix in seed.ts and claim_race.test.ts.
# PowerShell 5.1, ASCII only, idempotent.
# Run from: C:\Users\Apple\webhook-gateway

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

# ---- tests/helpers/seed.ts (resetData wrapped in BEGIN/SET LOCAL/TRUNCATE/COMMIT) ----
W 'tests\helpers\seed.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';

export const T          = '11111111-1111-4111-8111-111111111111';
export const TENANT_A   = '22222222-2222-4222-8222-222222222222';
export const TENANT_B   = '33333333-3333-4333-8333-333333333333';

async function ensureTenant(admin: Client, tenantId: string): Promise<void> {
  await admin.query(
    `INSERT INTO tenants (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING`,
    [tenantId, `tenant-${tenantId.slice(0, 8)}`],
  );
}

export async function resetData(admin: Client): Promise<void> {
  await admin.query('BEGIN');
  try {
    await admin.query("SET LOCAL lock_timeout = '5000ms'");
    await admin.query(`
      TRUNCATE TABLE
        delivery_attempts,
        deliveries,
        events,
        subscriptions,
        endpoint_secrets,
        endpoints,
        api_keys,
        tenants
      RESTART IDENTITY CASCADE
    `);
    await admin.query('COMMIT');
  } catch (err) {
    try { await admin.query('ROLLBACK'); } catch { /* ignore */ }
    throw err;
  }
}

export async function seedTenant(admin: Client, id?: string): Promise<{ id: string }> {
  const tenantId = id ?? randomUUID();
  await ensureTenant(admin, tenantId);
  return { id: tenantId };
}

export async function seedEndpoints(
  admin: Client,
  opts: { count: number; tenantId: string; enabled?: boolean; url?: string },
): Promise<Array<{ id: string; tenant_id: string }>> {
  await ensureTenant(admin, opts.tenantId);
  const enabled = opts.enabled ?? true;
  const url = opts.url ?? 'https://example.test/hook';
  const out: Array<{ id: string; tenant_id: string }> = [];
  for (let i = 0; i < opts.count; i++) {
    const id = randomUUID();
    await admin.query(
      `INSERT INTO endpoints (id, tenant_id, url, enabled) VALUES ($1, $2, $3, $4)`,
      [id, opts.tenantId, url, enabled],
    );
    out.push({ id, tenant_id: opts.tenantId });
  }
  return out;
}

export async function seedEvents(
  admin: Client,
  opts: { count: number; tenantId: string; eventType?: string },
): Promise<Array<{ id: string; tenant_id: string }>> {
  await ensureTenant(admin, opts.tenantId);
  const eventType = opts.eventType ?? 'test.event';
  const out: Array<{ id: string; tenant_id: string }> = [];
  for (let i = 0; i < opts.count; i++) {
    const id = randomUUID();
    await admin.query(
      `INSERT INTO events (id, tenant_id, event_type, payload_hash, payload_bytes)
       VALUES ($1, $2, $3, $4, $5)`,
      [id, opts.tenantId, eventType, Buffer.from([0]), Buffer.from('{}')],
    );
    out.push({ id, tenant_id: opts.tenantId });
  }
  return out;
}

export async function seedSecrets(
  admin: Client,
  opts: { endpointId: string; tenantId: string; count?: number },
): Promise<Array<{ id: string }>> {
  await ensureTenant(admin, opts.tenantId);
  const count = opts.count ?? 1;
  const out: Array<{ id: string }> = [];
  for (let i = 0; i < count; i++) {
    const id = randomUUID();
    await admin.query(
      `INSERT INTO endpoint_secrets (id, endpoint_id, tenant_id, secret_prefix, secret_ciphertext)
       VALUES ($1, $2, $3, $4, $5)`,
      [id, opts.endpointId, opts.tenantId, 'whsec_test', Buffer.from([1, 2, 3])],
    );
    out.push({ id });
  }
  return out;
}

export async function seedDeliveries(
  admin: Client,
  opts: {
    count: number;
    tenantId?: string;
    endpointId?: string;
    status?: 'pending' | 'processing' | 'succeeded' | 'dlq' | 'paused';
    attempts?: number;
    totalAttempts?: number;
    maxAttempts?: number;
    reclaimCount?: number;
    lockedUntilOffsetSec?: number;
    nextAttemptOffsetSec?: number;
  },
): Promise<Array<{ id: string; event_id: string; endpoint_id: string; tenant_id: string }>> {
  const tenantId = opts.tenantId ?? randomUUID();
  await ensureTenant(admin, tenantId);
  const status = opts.status ?? 'pending';
  const attempts = opts.attempts ?? 0;
  const totalAttempts = opts.totalAttempts ?? attempts;
  const maxAttempts = opts.maxAttempts ?? 8;
  const reclaimCount = opts.reclaimCount ?? 0;
  const lockOffset = opts.lockedUntilOffsetSec === undefined ? null : opts.lockedUntilOffsetSec;
  const nextOffset = opts.nextAttemptOffsetSec ?? 0;

  let endpointId = opts.endpointId;
  if (!endpointId) {
    const [ep] = await seedEndpoints(admin, { count: 1, tenantId });
    endpointId = ep.id;
  }

  const out: Array<{ id: string; event_id: string; endpoint_id: string; tenant_id: string }> = [];

  if (opts.count >= 100) {
    const rows = await admin.query(
      `WITH ev AS (
         INSERT INTO events (id, tenant_id, event_type, payload_hash, payload_bytes)
         SELECT gen_random_uuid(), $1, 'test.event',
                decode('00', 'hex'), decode('7b7d', 'hex')
         FROM generate_series(1, $2)
         RETURNING id
       )
       INSERT INTO deliveries
         (id, event_id, endpoint_id, tenant_id, status, attempts, total_attempts,
          max_attempts, reclaim_count, locked_until, next_attempt_at)
       SELECT gen_random_uuid(), ev.id, $3, $1, $4, $5, $6, $7, $8,
         CASE WHEN $9::int IS NULL THEN NULL
              ELSE now() + interval '1 second' * $9::int END,
         now() + interval '1 second' * $10::int
       FROM ev
       RETURNING id, event_id, endpoint_id, tenant_id`,
      [tenantId, opts.count, endpointId, status, attempts, totalAttempts,
       maxAttempts, reclaimCount, lockOffset, nextOffset],
    );
    for (const r of rows.rows) {
      out.push({ id: r.id, event_id: r.event_id,
                 endpoint_id: r.endpoint_id, tenant_id: r.tenant_id });
    }
    return out;
  }

  for (let i = 0; i < opts.count; i++) {
    const [ev] = await seedEvents(admin, { count: 1, tenantId });
    const id = randomUUID();
    await admin.query(
      `INSERT INTO deliveries
         (id, event_id, endpoint_id, tenant_id, status, attempts, total_attempts,
          max_attempts, reclaim_count, locked_until, next_attempt_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9,
         CASE WHEN $10::int IS NULL THEN NULL
              ELSE now() + interval '1 second' * $10::int END,
         now() + interval '1 second' * $11::int)`,
      [id, ev.id, endpointId, tenantId, status, attempts, totalAttempts,
       maxAttempts, reclaimCount, lockOffset, nextOffset],
    );
    out.push({ id, event_id: ev.id, endpoint_id: endpointId, tenant_id: tenantId });
  }
  return out;
}
'@

# ---- tests/integration/claim_race.test.ts (afterEach ROLLBACK of open test connections) ----
W 'tests\integration\claim_race.test.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries } from '../helpers/seed';
import { snapshotDeliveries } from '../helpers/snapshot';
import { claimSQL } from '../fixtures/sql';

let dbName: string;
let admin: Client;
let testClients: Client[] = [];

async function openConn(): Promise<Client> {
  const c = await connectAs(dbName, 'webhook_dispatcher');
  testClients.push(c);
  return c;
}

beforeAll(async () => {
  const r = await createTestDatabase();
  dbName = r.name;
  admin = r.pool;
});

afterAll(async () => {
  try {
    if (dbName) await dropTestDatabase(dbName);
  } finally {
    await closeAllClients();
  }
});

beforeEach(async () => {
  await resetData(admin);
});

afterEach(async () => {
  for (const c of testClients) {
    try { await c.query('ROLLBACK'); } catch { /* ignore */ }
  }
  testClients = [];
});

test('INV-RC-1: two open-transaction claims are disjoint, rollback restores state', async () => {
  for (let i = 0; i < 6; i++) {
    await seedDeliveries(admin, { count: 5, tenantId: randomUUID() });
  }
  const snapBefore = await snapshotDeliveries(admin);
  const c1 = await openConn();
  const c2 = await openConn();
  await c1.query('BEGIN');
  await c1.query("SET LOCAL lock_timeout = '1500ms'");
  await c2.query('BEGIN');
  await c2.query("SET LOCAL lock_timeout = '1500ms'");
  const r1 = await c1.query(claimSQL);
  const r2 = await c2.query(claimSQL);
  expect(r1.rowCount).toBeGreaterThan(0);
  expect(r2.rowCount).toBeGreaterThan(0);
  const ids1 = new Set(r1.rows.map((x: any) => x.id));
  const ids2 = new Set(r2.rows.map((x: any) => x.id));
  for (const id of ids1) {
    expect(ids2.has(id)).toBe(false);
  }
  await c1.query('ROLLBACK');
  await c2.query('ROLLBACK');
  const snapAfter = await snapshotDeliveries(admin);
  expect(snapAfter).toBe(snapBefore);
});

test('INV-RC-2: commit variant yields disjoint sets', async () => {
  for (let i = 0; i < 6; i++) {
    await seedDeliveries(admin, { count: 5, tenantId: randomUUID() });
  }
  const c1 = await openConn();
  await c1.query('BEGIN');
  await c1.query("SET LOCAL lock_timeout = '1500ms'");
  const r1 = await c1.query(claimSQL);
  await c1.query('COMMIT');

  const c2 = await openConn();
  await c2.query('BEGIN');
  await c2.query("SET LOCAL lock_timeout = '1500ms'");
  const r2 = await c2.query(claimSQL);
  await c2.query('COMMIT');

  expect(r1.rowCount).toBeGreaterThan(0);
  expect(r2.rowCount).toBeGreaterThan(0);
  const ids1 = new Set(r1.rows.map((x: any) => x.id));
  for (const row of r2.rows) {
    expect(ids1.has(row.id)).toBe(false);
  }
});

test('INV-RC-3: 8 concurrent claims over 4 tenants x 10 rows have no duplicate ids', async () => {
  for (let i = 0; i < 4; i++) {
    await seedDeliveries(admin, { count: 10, tenantId: randomUUID() });
  }
  const conns = await Promise.all(
    Array.from({ length: 8 }, () => openConn()),
  );
  const results = await Promise.all(conns.map(async (c) => {
    await c.query('BEGIN');
    await c.query("SET LOCAL lock_timeout = '1500ms'");
    const r = await c.query(claimSQL);
    await c.query('COMMIT');
    return r.rows as Array<{ id: string; lease_token: string }>;
  }));
  const allRows = results.flat();
  const allIds = allRows.map((r) => r.id);
  expect(new Set(allIds).size).toBe(allIds.length);
  for (const row of allRows) {
    const db = await admin.query(
      `SELECT status, lease_token, attempts FROM deliveries WHERE id = $1`, [row.id]);
    expect(db.rows[0].status).toBe('processing');
    expect(db.rows[0].lease_token).toBe(row.lease_token);
    expect(db.rows[0].attempts).toBe(1);
  }
});
'@

Write-Host ''
Write-Host 'Next commands:'
Write-Host '  npx tsc --noEmit'
Write-Host '  npx jest seed claim_race'
Write-Host '  $env:CLAIM_SQL_FILE=''sql/_mutants/C01.sql'''
Write-Host '  npx jest claim_race'
Write-Host '  Remove-Item Env:CLAIM_SQL_FILE'
Write-Host '  npx jest'
Write-Host ''
Write-Host 'Note: the mutant file sql/_mutants/C01.sql does not exist yet. Create it by'
Write-Host 'copying sql/claim.sql and replacing "FOR UPDATE SKIP LOCKED" with "FOR UPDATE",'
Write-Host 'or wait for mutation-check.ps1 -GenerateOnly.'