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