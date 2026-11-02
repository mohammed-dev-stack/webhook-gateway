# bootstrap-2b-2-seedfix.ps1
# PART 2b-2: rewrites tests/helpers/seed.ts and tests/fixtures/sql.ts as complete files.
# PowerShell 5.1, ASCII only, idempotent.

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

# ---- tests/helpers/seed.ts ----
W 'tests\helpers\seed.ts' @'
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';

export const T          = '11111111-1111-4111-8111-111111111111';
export const TENANT_A   = '22222222-2222-4222-8222-222222222222';
export const TENANT_B   = '33333333-3333-4333-8333-333333333333';

async function ensureTenant(admin: Client, tenantId: string): Promise<void> {
  await admin.query(
    `INSERT INTO tenants (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING`,
    [tenantId, `tenant-${tenantId.slice(0, 8)}`],
  );
}

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
  await ensureTenant(admin, tenantId);
  return { id: tenantId };
}

export async function seedEndpoints(
  admin: Client,
  opts: { count: number; tenantId: string; enabled?: boolean; url?: string },
): Promise<Array<{ id: string; tenant_id: string }>> {
  await ensureTenant(admin, opts.tenantId);
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
  await ensureTenant(admin, opts.tenantId);
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
  await ensureTenant(admin, opts.tenantId);
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
  const tenantId = opts.tenantId ?? randomUUID();
  await ensureTenant(admin, tenantId);
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
# TEST-ONLY env overrides exist solely for mutation checks (run a test against a
# deliberately broken SQL file to prove the test catches the regression). They are
# not used in normal runs and every override must be cleared with
# Remove-Item Env:NAME after the mutation run, because $env:NAME set in PowerShell
# persists for the session.
W 'tests\fixtures\sql.ts' @'
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

function readFromCwd(file: string): string {
  return readFileSync(join(process.cwd(), file), 'utf8');
}

export const claimSQL = readFromCwd(
  process.env.CLAIM_SQL_FILE ?? 'sql/claim.sql',
);
export const janitorSQL = readFromCwd(
  process.env.JANITOR_SQL_FILE ?? 'sql/janitor.sql',
);
export const releaseBreakerSQL = readFromCwd(
  process.env.RELEASE_BREAKER_SQL_FILE ?? 'sql/release_breaker.sql',
);
export const releaseShutdownSQL = readFromCwd(
  process.env.RELEASE_SHUTDOWN_SQL_FILE ?? 'sql/release_shutdown.sql',
);
export const claimOldFairnessSQL = readFromCwd(
  'sql/_experiments/claim_old_fairness.sql',
);
'@

Write-Host ''
Write-Host 'Next commands:'
Write-Host '  npx tsc --noEmit'
Write-Host '  npx jest seed'
Write-Host '  npx jest smoke'
Write-Host ''
Write-Host 'Reminder: an env override set with $env:NAME=''...'' persists in the PowerShell'
Write-Host 'session; clear it with Remove-Item Env:NAME after every mutation run.'