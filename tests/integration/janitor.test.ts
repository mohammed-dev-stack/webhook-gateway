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