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