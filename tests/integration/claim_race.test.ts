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