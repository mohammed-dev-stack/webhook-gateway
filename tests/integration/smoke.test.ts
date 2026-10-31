import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import {
  createTestDatabase,
  connectAs,
  closeAllClients,
  dropTestDatabase,
} from '../helpers/db';
import {
  claimSQL,
  janitorSQL,
  releaseBreakerSQL,
  releaseShutdownSQL,
  claimOldFairnessSQL,
} from '../fixtures/sql';

let dbName: string;
let admin: Client;

beforeAll(async () => {
  const r = await createTestDatabase();
  dbName = r.name;
  admin = r.pool;
});

afterAll(async () => {
  await closeAllClients();
  await dropTestDatabase(dbName);
});

test('9 tables exist', async () => {
  const r = await admin.query(
    `SELECT tablename FROM pg_tables
      WHERE schemaname = 'public' ORDER BY tablename`,
  );
  const names = r.rows.map((x: any) => x.tablename).sort();
  expect(names).toEqual([
    '_migrations', 'api_keys', 'deliveries', 'delivery_attempts',
    'endpoint_secrets', 'endpoints', 'events', 'subscriptions', 'tenants',
  ].sort());
});

test('RLS enabled and forced on the 6 tenant tables, off on the other 2', async () => {
  const r = await admin.query(
    `SELECT relname, relrowsecurity, relforcerowsecurity
       FROM pg_class
       WHERE relname IN ('tenants','endpoints','endpoint_secrets','subscriptions',
                         'events','deliveries','api_keys','delivery_attempts')
       ORDER BY relname`,
  );
  const byName: Record<string, { rls: boolean; force: boolean }> = {};
  for (const row of r.rows) {
    byName[row.relname] = { rls: row.relrowsecurity, force: row.relforcerowsecurity };
  }
  for (const n of ['tenants', 'endpoints', 'endpoint_secrets',
                   'subscriptions', 'events', 'deliveries']) {
    expect(byName[n]).toEqual({ rls: true, force: true });
  }
  for (const n of ['api_keys', 'delivery_attempts']) {
    expect(byName[n]).toEqual({ rls: false, force: false });
  }
});

test('4 webhook roles connect; bypass/super flags match', async () => {
  const expectations: Array<{ role: 'webhook_api' | 'webhook_dispatcher' | 'webhook_admin' | 'webhook_auth'; bypass: boolean }> = [
    { role: 'webhook_api',        bypass: false },
    { role: 'webhook_dispatcher', bypass: true  },
    { role: 'webhook_admin',      bypass: true  },
    { role: 'webhook_auth',       bypass: true  },
  ];
  for (const e of expectations) {
    const c = await connectAs(dbName, e.role);
    const r = await c.query(
      `SELECT rolbypassrls, rolsuper FROM pg_roles WHERE rolname = current_user`,
    );
    const row = r.rows[0];
    expect(row.rolsuper).toBe(false);
    expect(row.rolbypassrls).toBe(e.bypass);
  }
});

test('auth_resolve: SECURITY DEFINER, owner webhook_auth', async () => {
  const r = await admin.query(
    `SELECT p.prosecdef, r.rolname AS owner
       FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
       WHERE p.proname = 'auth_resolve'`,
  );
  expect(r.rows.length).toBe(1);
  expect(r.rows[0].prosecdef).toBe(true);
  expect(r.rows[0].owner).toBe('webhook_auth');
});

test('webhook_api: no direct api_keys access; auth_resolve returns zero rows', async () => {
  const c = await connectAs(dbName, 'webhook_api');
  await expect(c.query('SELECT * FROM api_keys')).rejects.toThrow(/permission denied/);
  const r = await c.query(`SELECT * FROM auth_resolve('nope')`);
  expect(r.rows).toEqual([]);
});

test('dispatcher executes all SQL files on empty DB without error', async () => {
  const c = await connectAs(dbName, 'webhook_dispatcher');
  const r1 = await c.query(claimSQL);
  expect(r1.rowCount).toBe(0);
  const r2 = await c.query(janitorSQL);
  expect(r2.rowCount).toBe(0);
  const r3 = await c.query(claimOldFairnessSQL);
  expect(r3.rowCount).toBe(0);
  const r4 = await c.query(releaseBreakerSQL, [randomUUID(), randomUUID()]);
  expect(r4.rowCount).toBe(0);
  const r5 = await c.query(releaseShutdownSQL, [randomUUID(), randomUUID()]);
  expect(r5.rowCount).toBe(0);
});