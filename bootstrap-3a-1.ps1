# bootstrap-3a-1.ps1
# PART 3A, SCRIPT A1: tests/helpers/snapshot.ts plus four test files.
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

# ---- tests/helpers/snapshot.ts ----
W 'tests\helpers\snapshot.ts' @'
import { Client } from 'pg';

export async function snapshotDeliveries(admin: Client): Promise<string> {
  const r = await admin.query(
    `SELECT id, event_id, endpoint_id, tenant_id, status, attempts, total_attempts,
            max_attempts, reclaim_count, next_attempt_at, locked_until, lease_token,
            last_error, created_at, updated_at
       FROM deliveries
       ORDER BY id`,
  );
  return JSON.stringify(r.rows);
}
'@

# ---- tests/integration/claim_basic.test.ts ----
W 'tests\integration\claim_basic.test.ts' @'
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

test('INV-CL-1: 4 due pending rows across 4 tenants are all claimed with distinct tokens', async () => {
  for (let i = 0; i < 4; i++) {
    await seedDeliveries(admin, { count: 1, tenantId: randomUUID() });
  }
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  const r = await dispatcher.query(claimSQL);
  expect(r.rowCount).toBe(4);
  const tokens = new Set<string>();
  for (const row of r.rows) {
    expect(row.lease_token).not.toBeNull();
    tokens.add(row.lease_token);
  }
  expect(tokens.size).toBe(4);
  for (const row of r.rows) {
    const db = await admin.query(
      `SELECT status, attempts, total_attempts, reclaim_count, lease_token,
              (locked_until BETWEEN now() + interval '25 seconds'
                                AND now() + interval '35 seconds') AS lock_ok
         FROM deliveries WHERE id = $1`, [row.id]);
    const d = db.rows[0];
    expect(d.status).toBe('processing');
    expect(d.attempts).toBe(1);
    expect(d.total_attempts).toBe(1);
    expect(d.reclaim_count).toBe(0);
    expect(d.lease_token).toBe(row.lease_token);
    expect(d.lock_ok).toBe(true);
  }
});

test('INV-CL-2: nothing claimable leaves the DB unchanged', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: randomUUID(), nextAttemptOffsetSec: 3600 });
  await seedDeliveries(admin, { count: 1, tenantId: randomUUID(), status: 'paused' });
  await seedDeliveries(admin, { count: 1, tenantId: randomUUID(), status: 'dlq' });
  await seedDeliveries(admin, { count: 1, tenantId: randomUUID(), status: 'succeeded' });
  await seedDeliveries(admin, { count: 1, tenantId: randomUUID(), attempts: 8, maxAttempts: 8 });
  await seedDeliveries(admin, {
    count: 1, tenantId: randomUUID(), status: 'processing',
    attempts: 1, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: 60,
  });

  const snapBefore = await snapshotDeliveries(admin);
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  const r = await dispatcher.query(claimSQL);
  expect(r.rowCount).toBe(0);
  const snapAfter = await snapshotDeliveries(admin);
  expect(snapAfter).toBe(snapBefore);
});

test('INV-CL-3: batch limit is 10 and no tenant appears more than twice', async () => {
  for (let i = 0; i < 12; i++) {
    await seedDeliveries(admin, { count: 3, tenantId: randomUUID() });
  }
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  const r = await dispatcher.query(claimSQL);
  expect(r.rowCount).toBe(10);
  const perTenant: Record<string, number> = {};
  for (const row of r.rows) {
    perTenant[row.tenant_id] = (perTenant[row.tenant_id] || 0) + 1;
  }
  for (const n of Object.values(perTenant)) {
    expect(n).toBeLessThanOrEqual(2);
  }
});

test('INV-CL-4: 3 tenants x 7 due rows drain in <=20 calls, 21 unique, all processing', async () => {
  for (let i = 0; i < 3; i++) {
    await seedDeliveries(admin, { count: 7, tenantId: randomUUID() });
  }
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  const seen = new Set<string>();
  let calls = 0;
  while (calls < 20) {
    const r = await dispatcher.query(claimSQL);
    calls++;
    if (r.rowCount === 0) break;
    for (const row of r.rows) {
      expect(seen.has(row.id)).toBe(false);
      seen.add(row.id);
    }
  }
  expect(calls).toBeLessThanOrEqual(20);
  expect(seen.size).toBe(21);
  const check = await admin.query(
    `SELECT COUNT(*)::int AS n FROM deliveries WHERE status = 'processing'`);
  expect(check.rows[0].n).toBe(21);
});
'@

# ---- tests/integration/claim_fairness.test.ts ----
W 'tests\integration\claim_fairness.test.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries } from '../helpers/seed';
import { claimSQL, claimOldFairnessSQL } from '../fixtures/sql';

let dbName: string;
let admin: Client;

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

test('INV-FA-1: noisy neighbor A (1000 older) and B (10 now) both appear, each <=2', async () => {
  const A = randomUUID();
  const B = randomUUID();
  await seedDeliveries(admin, { count: 1000, tenantId: A, nextAttemptOffsetSec: -3600 });
  await seedDeliveries(admin, { count: 10, tenantId: B });
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  const r = await dispatcher.query(claimSQL);
  const perTenant: Record<string, number> = {};
  for (const row of r.rows) {
    perTenant[row.tenant_id] = (perTenant[row.tenant_id] || 0) + 1;
  }
  expect(perTenant[A]).toBeGreaterThanOrEqual(1);
  expect(perTenant[B]).toBeGreaterThanOrEqual(1);
  expect(perTenant[A]).toBeLessThanOrEqual(2);
  expect(perTenant[B]).toBeLessThanOrEqual(2);
});

test('INV-FA-2: tenant B rows are all claimed within 5 calls despite A backlog', async () => {
  const A = randomUUID();
  const B = randomUUID();
  await seedDeliveries(admin, { count: 1000, tenantId: A, nextAttemptOffsetSec: -3600 });
  await seedDeliveries(admin, { count: 10, tenantId: B });
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  for (let i = 0; i < 5; i++) {
    await dispatcher.query(claimSQL);
  }
  const check = await admin.query(
    `SELECT COUNT(*)::int AS n FROM deliveries
       WHERE tenant_id = $1 AND status = 'processing'`, [B]);
  expect(check.rows[0].n).toBe(10);
});

test('INV-FA-3: old fairness query returns rows ONLY from tenant A (defect documented)', async () => {
  const A = randomUUID();
  const B = randomUUID();
  await seedDeliveries(admin, { count: 1000, tenantId: A, nextAttemptOffsetSec: -3600 });
  await seedDeliveries(admin, { count: 10, tenantId: B });
  const dispatcher = await connectAs(dbName, 'webhook_dispatcher');
  const r = await dispatcher.query(claimOldFairnessSQL);
  expect(r.rowCount).toBeGreaterThan(0);
  for (const row of r.rows) {
    expect(row.tenant_id).toBe(A);
  }
});
'@

# ---- tests/integration/claim_race.test.ts ----
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

test('INV-RC-1: two open-transaction claims are disjoint, rollback restores state', async () => {
  for (let i = 0; i < 6; i++) {
    await seedDeliveries(admin, { count: 5, tenantId: randomUUID() });
  }
  const snapBefore = await snapshotDeliveries(admin);
  const c1 = await connectAs(dbName, 'webhook_dispatcher');
  const c2 = await connectAs(dbName, 'webhook_dispatcher');
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
  const c1 = await connectAs(dbName, 'webhook_dispatcher');
  await c1.query('BEGIN');
  await c1.query("SET LOCAL lock_timeout = '1500ms'");
  const r1 = await c1.query(claimSQL);
  await c1.query('COMMIT');

  const c2 = await connectAs(dbName, 'webhook_dispatcher');
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
    Array.from({ length: 8 }, () => connectAs(dbName, 'webhook_dispatcher')),
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

# ---- tests/integration/crash_recovery.test.ts ----
W 'tests\integration\crash_recovery.test.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries, T } from '../helpers/seed';
import { claimSQL, janitorSQL } from '../fixtures/sql';

let dbName: string;
let admin: Client;

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

test('INV-CR-1: reclaim yields new token, attempts+1, reclaim_count+1, fresh lease', async () => {
  const [d] = await seedDeliveries(admin, { count: 1, tenantId: T });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r1 = await c.query(claimSQL);
  expect(r1.rowCount).toBe(1);
  const lease1 = r1.rows[0].lease_token;
  await admin.query(
    `UPDATE deliveries SET locked_until = now() - interval '1 second' WHERE id = $1`,
    [d.id]);
  const r2 = await c.query(claimSQL);
  expect(r2.rowCount).toBe(1);
  const lease2 = r2.rows[0].lease_token;
  expect(lease2).not.toBe(lease1);
  const db = await admin.query(
    `SELECT status, attempts, total_attempts, reclaim_count,
            (locked_until > now()) AS lock_future
       FROM deliveries WHERE id = $1`, [d.id]);
  const row = db.rows[0];
  expect(row.status).toBe('processing');
  expect(row.attempts).toBe(2);
  expect(row.total_attempts).toBe(2);
  expect(row.reclaim_count).toBe(1);
  expect(row.lock_future).toBe(true);
});

test('INV-CR-2: unexpired lease is not reclaimed', async () => {
  await seedDeliveries(admin, {
    count: 1, tenantId: T, status: 'processing',
    attempts: 1, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: 60,
  });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(claimSQL);
  expect(r.rowCount).toBe(0);
});

test('INV-CR-3: budget edge reclaims only attempts=max, not attempts=max+1 or reclaim_count=3', async () => {
  const A = randomUUID();
  const B = randomUUID();
  const C = randomUUID();
  await seedDeliveries(admin, { count: 1, tenantId: A, status: 'processing',
    attempts: 8, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: -1 });
  await seedDeliveries(admin, { count: 1, tenantId: B, status: 'processing',
    attempts: 9, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: -1 });
  await seedDeliveries(admin, { count: 1, tenantId: C, status: 'processing',
    attempts: 2, maxAttempts: 8, reclaimCount: 3, lockedUntilOffsetSec: -1 });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(claimSQL);
  expect(r.rowCount).toBe(1);
  expect(r.rows[0].tenant_id).toBe(A);
  expect(r.rows[0].attempts).toBe(9);
});

test('INV-CR-4: reclaim bound at 3, then janitor moves row to dlq', async () => {
  const [d] = await seedDeliveries(admin, { count: 1, tenantId: T, maxAttempts: 8 });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  async function claimOne(): Promise<string | null> {
    const r = await c.query(claimSQL);
    if (r.rowCount === 0) return null;
    const row = r.rows.find((x: any) => x.id === d.id);
    return row ? (row.lease_token as string) : null;
  }
  async function expire(): Promise<void> {
    await admin.query(
      `UPDATE deliveries SET locked_until = now() - interval '1 second' WHERE id = $1`,
      [d.id]);
  }
  async function inspect(): Promise<any> {
    const r = await admin.query(
      `SELECT status, attempts, total_attempts, reclaim_count
         FROM deliveries WHERE id = $1`, [d.id]);
    return r.rows[0];
  }
  expect(await claimOne()).not.toBeNull();
  let s = await inspect();
  expect(s.attempts).toBe(1);
  expect(s.reclaim_count).toBe(0);

  await expire();
  expect(await claimOne()).not.toBeNull();
  s = await inspect();
  expect(s.attempts).toBe(2);
  expect(s.reclaim_count).toBe(1);

  await expire();
  expect(await claimOne()).not.toBeNull();
  s = await inspect();
  expect(s.attempts).toBe(3);
  expect(s.reclaim_count).toBe(2);

  await expire();
  expect(await claimOne()).not.toBeNull();
  s = await inspect();
  expect(s.attempts).toBe(4);
  expect(s.reclaim_count).toBe(3);

  await expire();
  expect(await claimOne()).toBeNull();
  s = await inspect();
  expect(s.status).toBe('processing');
  expect(s.reclaim_count).toBe(3);

  const jr = await c.query(janitorSQL);
  expect(jr.rowCount).toBe(1);
  s = await inspect();
  expect(s.status).toBe('dlq');
});

test.todo('INV-CR-5 (R5-1): a processing row with NULL locked_until is never reclaimed and never janitored');
'@

Write-Host ''
Write-Host 'Next commands:'
Write-Host '  npx tsc --noEmit'
Write-Host '  npx jest claim_basic'
Write-Host '  npx jest claim_fairness'
Write-Host '  npx jest claim_race'
Write-Host '  npx jest crash_recovery'