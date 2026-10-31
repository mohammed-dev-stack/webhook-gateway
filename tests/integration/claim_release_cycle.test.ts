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