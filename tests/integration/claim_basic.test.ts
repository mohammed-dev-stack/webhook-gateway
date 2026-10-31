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