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