# bootstrap-3a-2.ps1
# PART 3A, SCRIPT A2: janitor, releases, cycle, pending-sql todos.
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

# ---- tests/integration/janitor.test.ts ----
W 'tests\integration\janitor.test.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries } from '../helpers/seed';
import { snapshotDeliveries } from '../helpers/snapshot';
import { janitorSQL } from '../fixtures/sql';

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

test('INV-JA-1: reclaim_count >= 3 hits; last_error COALESCE preserves non-null', async () => {
  const A = randomUUID();
  const B = randomUUID();
  await seedDeliveries(admin, {
    count: 1, tenantId: A, status: 'processing',
    attempts: 2, maxAttempts: 8, reclaimCount: 3, lockedUntilOffsetSec: -1,
  });
  await seedDeliveries(admin, {
    count: 1, tenantId: B, status: 'processing',
    attempts: 2, maxAttempts: 8, reclaimCount: 3, lockedUntilOffsetSec: -1,
  });
  await admin.query(
    `UPDATE deliveries SET last_error = 'boom' WHERE tenant_id = $1`, [B]);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(janitorSQL);
  expect(r.rowCount).toBe(2);
  const rows = await admin.query(
    `SELECT tenant_id, status, lease_token, locked_until, last_error
       FROM deliveries WHERE tenant_id IN ($1, $2)`, [A, B]);
  const byTenant: Record<string, any> = {};
  for (const row of rows.rows) byTenant[row.tenant_id] = row;
  expect(byTenant[A].status).toBe('dlq');
  expect(byTenant[A].lease_token).toBeNull();
  expect(byTenant[A].locked_until).toBeNull();
  expect(byTenant[A].last_error).toBe('janitor: stuck row');
  expect(byTenant[B].status).toBe('dlq');
  expect(byTenant[B].last_error).toBe('boom');
});

test('INV-JA-2: attempts > max_attempts alone triggers janitor (C1)', async () => {
  const A = randomUUID();
  await seedDeliveries(admin, {
    count: 1, tenantId: A, status: 'processing',
    attempts: 9, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: -1,
  });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(janitorSQL);
  expect(r.rowCount).toBe(1);
  const check = await admin.query(
    `SELECT status FROM deliveries WHERE tenant_id = $1`, [A]);
  expect(check.rows[0].status).toBe('dlq');
});

test('INV-JA-3: attempts = max_attempts and reclaim_count 0 is left for claim to reclaim', async () => {
  const A = randomUUID();
  await seedDeliveries(admin, {
    count: 1, tenantId: A, status: 'processing',
    attempts: 8, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: -1,
  });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(janitorSQL);
  expect(r.rowCount).toBe(0);
  const check = await admin.query(
    `SELECT status FROM deliveries WHERE tenant_id = $1`, [A]);
  expect(check.rows[0].status).toBe('processing');
});

test('INV-JA-4: unexpired processing with reclaim_count 3 and attempts 9 is untouched', async () => {
  const A = randomUUID();
  await seedDeliveries(admin, {
    count: 1, tenantId: A, status: 'processing',
    attempts: 9, maxAttempts: 8, reclaimCount: 3, lockedUntilOffsetSec: 60,
  });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(janitorSQL);
  expect(r.rowCount).toBe(0);
  const check = await admin.query(
    `SELECT status FROM deliveries WHERE tenant_id = $1`, [A]);
  expect(check.rows[0].status).toBe('processing');
});

test('INV-JA-5: pending, paused, dlq, succeeded rows are untouched', async () => {
  const A = randomUUID();
  await seedDeliveries(admin, { count: 1, tenantId: A, status: 'pending', nextAttemptOffsetSec: -3600 });
  await seedDeliveries(admin, { count: 1, tenantId: A, status: 'paused' });
  await seedDeliveries(admin, { count: 1, tenantId: A, status: 'dlq' });
  await seedDeliveries(admin, { count: 1, tenantId: A, status: 'succeeded' });
  const snapBefore = await snapshotDeliveries(admin);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(janitorSQL);
  expect(r.rowCount).toBe(0);
  const snapAfter = await snapshotDeliveries(admin);
  expect(snapAfter).toBe(snapBefore);
});

test('INV-JA-6: RETURNING ids equal exactly the moved rows', async () => {
  const A = randomUUID();
  const B = randomUUID();
  const C = randomUUID();
  const [hit1] = await seedDeliveries(admin, {
    count: 1, tenantId: A, status: 'processing',
    attempts: 9, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: -1,
  });
  const [hit2] = await seedDeliveries(admin, {
    count: 1, tenantId: B, status: 'processing',
    attempts: 2, maxAttempts: 8, reclaimCount: 3, lockedUntilOffsetSec: -1,
  });
  await seedDeliveries(admin, {
    count: 1, tenantId: C, status: 'processing',
    attempts: 1, maxAttempts: 8, reclaimCount: 0, lockedUntilOffsetSec: 60,
  });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(janitorSQL);
  const ids = new Set(r.rows.map((x: any) => x.id));
  expect(ids.size).toBe(2);
  expect(ids.has(hit1.id)).toBe(true);
  expect(ids.has(hit2.id)).toBe(true);
});
'@

# ---- tests/integration/release_breaker.test.ts ----
W 'tests\integration\release_breaker.test.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries, T } from '../helpers/seed';
import { snapshotDeliveries } from '../helpers/snapshot';
import { claimSQL, releaseBreakerSQL } from '../fixtures/sql';

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

async function claimOne(): Promise<{ id: string; token: string }> {
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(claimSQL);
  if (r.rowCount !== 1) throw new Error('expected exactly one claim, got ' + r.rowCount);
  return { id: r.rows[0].id, token: r.rows[0].lease_token };
}

test('INV-RB-1: release undoes claim, no attempt row, next_attempt_at ~ +30s', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id, token } = await claimOne();
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(releaseBreakerSQL, [id, token]);
  expect(r.rowCount).toBe(1);
  const row = await admin.query(
    `SELECT status, attempts, total_attempts, lease_token, locked_until, reclaim_count,
            (next_attempt_at BETWEEN now() + interval '25 seconds'
                                 AND now() + interval '35 seconds') AS next_ok
       FROM deliveries WHERE id = $1`, [id]);
  const d = row.rows[0];
  expect(d.status).toBe('pending');
  expect(d.attempts).toBe(0);
  expect(d.total_attempts).toBe(0);
  expect(d.lease_token).toBeNull();
  expect(d.locked_until).toBeNull();
  expect(d.reclaim_count).toBe(0);
  expect(d.next_ok).toBe(true);
  const att = await admin.query(
    `SELECT COUNT(*)::int AS n FROM delivery_attempts WHERE delivery_id = $1`, [id]);
  expect(att.rows[0].n).toBe(0);
});

test('INV-RB-2: wrong token affects 0 rows and snapshot is unchanged', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id } = await claimOne();
  const snapBefore = await snapshotDeliveries(admin);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(releaseBreakerSQL, [id, randomUUID()]);
  expect(r.rowCount).toBe(0);
  const snapAfter = await snapshotDeliveries(admin);
  expect(snapAfter).toBe(snapBefore);
});

test('INV-RB-3: second release with same token affects 0 rows and does not double-decrement', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id, token } = await claimOne();
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r1 = await c.query(releaseBreakerSQL, [id, token]);
  expect(r1.rowCount).toBe(1);
  const r2 = await c.query(releaseBreakerSQL, [id, token]);
  expect(r2.rowCount).toBe(0);
  const row = await admin.query(
    `SELECT attempts, total_attempts FROM deliveries WHERE id = $1`, [id]);
  expect(row.rows[0].attempts).toBe(0);
  expect(row.rows[0].total_attempts).toBe(0);
});

test('INV-RB-4: stale token after takeover is rejected; new token is accepted', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id, token: t1 } = await claimOne();
  await admin.query(
    `UPDATE deliveries SET locked_until = now() - interval '1 second' WHERE id = $1`, [id]);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r2 = await c.query(claimSQL);
  const t2 = r2.rows[0].lease_token;
  expect(t2).not.toBe(t1);
  const stale = await c.query(releaseBreakerSQL, [id, t1]);
  expect(stale.rowCount).toBe(0);
  const still = await admin.query(
    `SELECT status, lease_token FROM deliveries WHERE id = $1`, [id]);
  expect(still.rows[0].status).toBe('processing');
  expect(still.rows[0].lease_token).toBe(t2);
  const fresh = await c.query(releaseBreakerSQL, [id, t2]);
  expect(fresh.rowCount).toBe(1);
});
'@

# ---- tests/integration/release_shutdown.test.ts ----
W 'tests\integration\release_shutdown.test.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries, T } from '../helpers/seed';
import { snapshotDeliveries } from '../helpers/snapshot';
import { claimSQL, releaseShutdownSQL } from '../fixtures/sql';

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

async function claimOne(): Promise<{ id: string; token: string }> {
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(claimSQL);
  if (r.rowCount !== 1) throw new Error('expected exactly one claim, got ' + r.rowCount);
  return { id: r.rows[0].id, token: r.rows[0].lease_token };
}

test('INV-RS-1: release undoes claim, no attempt row, row is claimable immediately', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id, token } = await claimOne();
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(releaseShutdownSQL, [id, token]);
  expect(r.rowCount).toBe(1);
  const row = await admin.query(
    `SELECT status, attempts, total_attempts, lease_token, locked_until, reclaim_count,
            (next_attempt_at <= now()) AS next_due
       FROM deliveries WHERE id = $1`, [id]);
  const d = row.rows[0];
  expect(d.status).toBe('pending');
  expect(d.attempts).toBe(0);
  expect(d.total_attempts).toBe(0);
  expect(d.lease_token).toBeNull();
  expect(d.locked_until).toBeNull();
  expect(d.reclaim_count).toBe(0);
  expect(d.next_due).toBe(true);
  const att = await admin.query(
    `SELECT COUNT(*)::int AS n FROM delivery_attempts WHERE delivery_id = $1`, [id]);
  expect(att.rows[0].n).toBe(0);
  const reclaim = await c.query(claimSQL);
  expect(reclaim.rowCount).toBe(1);
  expect(reclaim.rows[0].id).toBe(id);
});

test('INV-RS-2: wrong token affects 0 rows and snapshot is unchanged', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id } = await claimOne();
  const snapBefore = await snapshotDeliveries(admin);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(releaseShutdownSQL, [id, randomUUID()]);
  expect(r.rowCount).toBe(0);
  const snapAfter = await snapshotDeliveries(admin);
  expect(snapAfter).toBe(snapBefore);
});

test('INV-RS-3: second release with same token affects 0 rows and does not double-decrement', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id, token } = await claimOne();
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r1 = await c.query(releaseShutdownSQL, [id, token]);
  expect(r1.rowCount).toBe(1);
  const r2 = await c.query(releaseShutdownSQL, [id, token]);
  expect(r2.rowCount).toBe(0);
  const row = await admin.query(
    `SELECT attempts, total_attempts FROM deliveries WHERE id = $1`, [id]);
  expect(row.rows[0].attempts).toBe(0);
  expect(row.rows[0].total_attempts).toBe(0);
});

test('INV-RS-4: stale token after takeover is rejected; new token is accepted', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const { id, token: t1 } = await claimOne();
  await admin.query(
    `UPDATE deliveries SET locked_until = now() - interval '1 second' WHERE id = $1`, [id]);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r2 = await c.query(claimSQL);
  const t2 = r2.rows[0].lease_token;
  expect(t2).not.toBe(t1);
  const stale = await c.query(releaseShutdownSQL, [id, t1]);
  expect(stale.rowCount).toBe(0);
  const still = await admin.query(
    `SELECT status, lease_token FROM deliveries WHERE id = $1`, [id]);
  expect(still.rows[0].status).toBe('processing');
  expect(still.rows[0].lease_token).toBe(t2);
  const fresh = await c.query(releaseShutdownSQL, [id, t2]);
  expect(fresh.rowCount).toBe(1);
});
'@

# ---- tests/integration/claim_release_cycle.test.ts ----
W 'tests\integration\claim_release_cycle.test.ts' @'
import { Client } from 'pg';
import {
  createTestDatabase, connectAs, closeAllClients, dropTestDatabase,
} from '../helpers/db';
import { resetData, seedDeliveries, T } from '../helpers/seed';
import { claimSQL, releaseBreakerSQL, releaseShutdownSQL } from '../fixtures/sql';

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

async function forceDue(id: string): Promise<void> {
  await admin.query(
    `UPDATE deliveries SET next_attempt_at = now() - interval '1 second' WHERE id = $1`,
    [id]);
}

async function claimOne(): Promise<{ id: string; token: string }> {
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r = await c.query(claimSQL);
  if (r.rowCount !== 1) throw new Error('expected exactly one claim, got ' + r.rowCount);
  return { id: r.rows[0].id, token: r.rows[0].lease_token };
}

const variants = [
  { name: 'breaker', sql: releaseBreakerSQL },
  { name: 'shutdown', sql: releaseShutdownSQL },
];

for (const v of variants) {
  test('INV-CY-1 ' + v.name + ': claim -> release -> claim restores fresh state', async () => {
    await seedDeliveries(admin, { count: 1, tenantId: T });
    const first = await claimOne();
    const c = await connectAs(dbName, 'webhook_dispatcher');
    const rel = await c.query(v.sql, [first.id, first.token]);
    expect(rel.rowCount).toBe(1);
    await forceDue(first.id);
    const second = await claimOne();
    expect(second.id).toBe(first.id);
    expect(second.token).not.toBe(first.token);
    const row = await admin.query(
      `SELECT attempts, total_attempts, reclaim_count FROM deliveries WHERE id = $1`,
      [first.id]);
    expect(row.rows[0].attempts).toBe(1);
    expect(row.rows[0].total_attempts).toBe(1);
    expect(row.rows[0].reclaim_count).toBe(0);
  });
}

test('INV-CY-2: release does not reset reclaim_count (design question)', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T, maxAttempts: 8 });
  const first = await claimOne();
  await admin.query(
    `UPDATE deliveries SET locked_until = now() - interval '1 second' WHERE id = $1`,
    [first.id]);
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const second = await c.query(claimSQL);
  const t2 = second.rows[0].lease_token;
  const pre = await admin.query(
    `SELECT attempts, total_attempts, reclaim_count FROM deliveries WHERE id = $1`,
    [first.id]);
  expect(pre.rows[0].attempts).toBe(2);
  expect(pre.rows[0].total_attempts).toBe(2);
  expect(pre.rows[0].reclaim_count).toBe(1);
  const rel = await c.query(releaseBreakerSQL, [first.id, t2]);
  expect(rel.rowCount).toBe(1);
  const post = await admin.query(
    `SELECT attempts, total_attempts, reclaim_count FROM deliveries WHERE id = $1`,
    [first.id]);
  expect(post.rows[0].attempts).toBe(1);
  expect(post.rows[0].total_attempts).toBe(1);
  expect(post.rows[0].reclaim_count).toBe(1);
});

test('INV-CY-3: 5 claim/release cycles on one row end at 0 and never go negative', async () => {
  await seedDeliveries(admin, { count: 1, tenantId: T });
  const c = await connectAs(dbName, 'webhook_dispatcher');
  let lastId = '';
  for (let i = 0; i < 5; i++) {
    const r = await c.query(claimSQL);
    expect(r.rowCount).toBe(1);
    lastId = r.rows[0].id;
    const rel = await c.query(releaseBreakerSQL, [lastId, r.rows[0].lease_token]);
    expect(rel.rowCount).toBe(1);
    const row = await admin.query(
      `SELECT attempts, total_attempts FROM deliveries WHERE id = $1`, [lastId]);
    expect(row.rows[0].attempts).toBe(0);
    expect(row.rows[0].total_attempts).toBe(0);
    await forceDue(lastId);
  }
  const final = await admin.query(
    `SELECT attempts, total_attempts FROM deliveries WHERE id = $1`, [lastId]);
  expect(final.rows[0].attempts).toBe(0);
  expect(final.rows[0].total_attempts).toBe(0);
});
'@

# ---- tests/integration/pending_sql.test.ts (todos only) ----
W 'tests\integration\pending_sql.test.ts' @'
// Production SQL files that the dispatcher needs but do not exist yet.
// Tracked as test.todo so the count of pending capabilities is visible in Jest output.
// When the corresponding SQL file is written, replace each todo with a real test.

test.todo('TODO FENCED-SUCCESS: fenced success write (not yet in production SQL)');
test.todo('TODO FENCED-RETRY: fenced retryable-failure write (not yet in production SQL)');
test.todo('TODO FENCED-PERM: fenced permanent-failure write (not yet in production SQL)');
test.todo('TODO REDRIVE: redrive (not yet in production SQL)');
test.todo('TODO ENDPOINT-DISABLE: endpoint disable/enable (not yet in production SQL)');
'@

Write-Host ''
Write-Host 'Next commands:'
Write-Host '  npx tsc --noEmit'
Write-Host '  npx jest janitor'
Write-Host '  npx jest release_breaker'
Write-Host '  npx jest release_shutdown'
Write-Host '  npx jest claim_release_cycle'
Write-Host '  npx jest pending_sql'