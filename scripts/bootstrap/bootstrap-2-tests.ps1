# bootstrap-2-tests.ps1
# PART 2: test helpers, fixtures, and smoke test.
# PowerShell 5.1, ASCII only, idempotent.
# Run from: C:\Users\Apple\webhook-gateway
# Precondition: migrate succeeded; 9 tables and 4 roles exist.

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

# ---- tests/helpers/db.ts ----
W 'tests\helpers\db.ts' @'
import { Client } from 'pg';
import { migrate } from '../../src/db/migrate';

const HOST = '127.0.0.1';
const PORT = Number(process.env.PGPORT ?? 5433);

const PASSWORDS: Record<string, string> = {
  postgres: process.env.PGPASSWORD ?? 'postgres',
  webhook_api: 'change_me',
  webhook_dispatcher: 'change_me',
  webhook_admin: 'change_me',
  webhook_auth: 'change_me',
};

export type Role =
  | 'postgres'
  | 'webhook_api'
  | 'webhook_dispatcher'
  | 'webhook_admin'
  | 'webhook_auth';

export const ADMIN_CONN = {
  host: HOST,
  port: PORT,
  user: 'postgres',
  password: PASSWORDS.postgres,
  database: 'postgres',
};

const registeredClients: Client[] = [];

function track(c: Client): Client {
  registeredClients.push(c);
  return c;
}

export async function createTestDatabase(): Promise<{ name: string; pool: Client }> {
  const admin = new Client(ADMIN_CONN);
  await admin.connect();
  const name = `whtest_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  try {
    await admin.query(`CREATE DATABASE ${name}`);
  } finally {
    await admin.end();
  }
  await migrate(name);
  const pool = new Client({
    host: HOST, port: PORT, user: 'postgres',
    password: PASSWORDS.postgres, database: name,
  });
  await pool.connect();
  track(pool);
  return { name, pool };
}

export async function connectAs(dbName: string, role: Role): Promise<Client> {
  const c = new Client({
    host: HOST, port: PORT, user: role,
    password: PASSWORDS[role], database: dbName,
  });
  await c.connect();
  track(c);
  return c;
}

export async function closeAllClients(): Promise<void> {
  while (registeredClients.length > 0) {
    const c = registeredClients.pop() as Client;
    try { await c.end(); } catch { /* already ended */ }
  }
}

export async function dropTestDatabase(name: string): Promise<void> {
  await closeAllClients();
  const admin = new Client(ADMIN_CONN);
  await admin.connect();
  try {
    await admin.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
  } finally {
    await admin.end();
  }
}
'@

# ---- tests/helpers/seed.ts ----
W 'tests\helpers\seed.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';

export const T          = '11111111-1111-4111-8111-111111111111';
export const TENANT_A   = '22222222-2222-4222-8222-222222222222';
export const TENANT_B   = '33333333-3333-4333-8333-333333333333';

export async function resetData(admin: Client): Promise<void> {
  await admin.query(`
    TRUNCATE TABLE
      delivery_attempts,
      deliveries,
      events,
      subscriptions,
      endpoint_secrets,
      endpoints,
      api_keys,
      tenants
    RESTART IDENTITY CASCADE
  `);
}

export async function seedTenant(admin: Client, id?: string): Promise<{ id: string }> {
  const tenantId = id ?? randomUUID();
  if (id) {
    await admin.query(
      `INSERT INTO tenants (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING`,
      [tenantId, `tenant-${tenantId.slice(0, 8)}`],
    );
  } else {
    await admin.query(
      `INSERT INTO tenants (id, name) VALUES ($1, $2)`,
      [tenantId, `tenant-${tenantId.slice(0, 8)}`],
    );
  }
  return { id: tenantId };
}

export async function seedEndpoints(
  admin: Client,
  opts: { count: number; tenantId: string; enabled?: boolean; url?: string },
): Promise<Array<{ id: string; tenant_id: string }>> {
  const enabled = opts.enabled ?? true;
  const url = opts.url ?? 'https://example.test/hook';
  const out: Array<{ id: string; tenant_id: string }> = [];
  for (let i = 0; i < opts.count; i++) {
    const id = randomUUID();
    await admin.query(
      `INSERT INTO endpoints (id, tenant_id, url, enabled) VALUES ($1, $2, $3, $4)`,
      [id, opts.tenantId, url, enabled],
    );
    out.push({ id, tenant_id: opts.tenantId });
  }
  return out;
}

export async function seedEvents(
  admin: Client,
  opts: { count: number; tenantId: string; eventType?: string },
): Promise<Array<{ id: string; tenant_id: string }>> {
  const eventType = opts.eventType ?? 'test.event';
  const out: Array<{ id: string; tenant_id: string }> = [];
  for (let i = 0; i < opts.count; i++) {
    const id = randomUUID();
    await admin.query(
      `INSERT INTO events (id, tenant_id, event_type, payload_hash, payload_bytes)
       VALUES ($1, $2, $3, $4, $5)`,
      [id, opts.tenantId, eventType, Buffer.from([0]), Buffer.from('{}')],
    );
    out.push({ id, tenant_id: opts.tenantId });
  }
  return out;
}

export async function seedSecrets(
  admin: Client,
  opts: { endpointId: string; tenantId: string; count?: number },
): Promise<Array<{ id: string }>> {
  const count = opts.count ?? 1;
  const out: Array<{ id: string }> = [];
  for (let i = 0; i < count; i++) {
    const id = randomUUID();
    await admin.query(
      `INSERT INTO endpoint_secrets (id, endpoint_id, tenant_id, secret_prefix, secret_ciphertext)
       VALUES ($1, $2, $3, $4, $5)`,
      [id, opts.endpointId, opts.tenantId, 'whsec_test', Buffer.from([1, 2, 3])],
    );
    out.push({ id });
  }
  return out;
}

export async function seedDeliveries(
  admin: Client,
  opts: {
    count: number;
    tenantId?: string;
    endpointId?: string;
    status?: 'pending' | 'processing' | 'succeeded' | 'dlq' | 'paused';
    attempts?: number;
    totalAttempts?: number;
    maxAttempts?: number;
    reclaimCount?: number;
    lockedUntilOffsetSec?: number;
    nextAttemptOffsetSec?: number;
  },
): Promise<Array<{ id: string; event_id: string; endpoint_id: string; tenant_id: string }>> {
  const tenantId = opts.tenantId ?? (await seedTenant(admin)).id;
  const status = opts.status ?? 'pending';
  const attempts = opts.attempts ?? 0;
  const totalAttempts = opts.totalAttempts ?? attempts;
  const maxAttempts = opts.maxAttempts ?? 8;
  const reclaimCount = opts.reclaimCount ?? 0;
  const lockOffset = opts.lockedUntilOffsetSec === undefined ? null : opts.lockedUntilOffsetSec;
  const nextOffset = opts.nextAttemptOffsetSec ?? 0;

  let endpointId = opts.endpointId;
  if (!endpointId) {
    const [ep] = await seedEndpoints(admin, { count: 1, tenantId });
    endpointId = ep.id;
  }

  const out: Array<{ id: string; event_id: string; endpoint_id: string; tenant_id: string }> = [];

  if (opts.count >= 100) {
    const rows = await admin.query(
      `WITH ev AS (
         INSERT INTO events (id, tenant_id, event_type, payload_hash, payload_bytes)
         SELECT gen_random_uuid(), $1, 'test.event',
                decode('00', 'hex'), decode('7b7d', 'hex')
         FROM generate_series(1, $2)
         RETURNING id
       )
       INSERT INTO deliveries
         (id, event_id, endpoint_id, tenant_id, status, attempts, total_attempts,
          max_attempts, reclaim_count, locked_until, next_attempt_at)
       SELECT gen_random_uuid(), ev.id, $3, $1, $4, $5, $6, $7, $8,
         CASE WHEN $9::int IS NULL THEN NULL
              ELSE now() + interval '1 second' * $9::int END,
         now() + interval '1 second' * $10::int
       FROM ev
       RETURNING id, event_id, endpoint_id, tenant_id`,
      [tenantId, opts.count, endpointId, status, attempts, totalAttempts,
       maxAttempts, reclaimCount, lockOffset, nextOffset],
    );
    for (const r of rows.rows) {
      out.push({ id: r.id, event_id: r.event_id,
                 endpoint_id: r.endpoint_id, tenant_id: r.tenant_id });
    }
    return out;
  }

  for (let i = 0; i < opts.count; i++) {
    const [ev] = await seedEvents(admin, { count: 1, tenantId });
    const id = randomUUID();
    await admin.query(
      `INSERT INTO deliveries
         (id, event_id, endpoint_id, tenant_id, status, attempts, total_attempts,
          max_attempts, reclaim_count, locked_until, next_attempt_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9,
         CASE WHEN $10::int IS NULL THEN NULL
              ELSE now() + interval '1 second' * $10::int END,
         now() + interval '1 second' * $11::int)`,
      [id, ev.id, endpointId, tenantId, status, attempts, totalAttempts,
       maxAttempts, reclaimCount, lockOffset, nextOffset],
    );
    out.push({ id, event_id: ev.id, endpoint_id: endpointId, tenant_id: tenantId });
  }
  return out;
}
'@

# ---- tests/fixtures/sql.ts ----
W 'tests\fixtures\sql.ts' @'
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

function readFromCwd(file: string): string {
  return readFileSync(join(process.cwd(), file), 'utf8');
}

export const claimSQL = readFileSync(
  join(process.cwd(), process.env.CLAIM_SQL_FILE ?? 'sql/claim.sql'),
  'utf8',
);
export const janitorSQL = readFromCwd('sql/janitor.sql');
export const releaseBreakerSQL = readFromCwd('sql/release_breaker.sql');
export const releaseShutdownSQL = readFromCwd('sql/release_shutdown.sql');
export const claimOldFairnessSQL = readFromCwd('sql/_experiments/claim_old_fairness.sql');
'@

# ---- tests/integration/smoke.test.ts ----
W 'tests\integration\smoke.test.ts' @'
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
'@

Write-Host ''
Write-Host 'Next commands:'
Write-Host '  npx tsc --noEmit'
Write-Host '  npx jest smoke'
Write-Host '  Get-ChildItem db\migrations'