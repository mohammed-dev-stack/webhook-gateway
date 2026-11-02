# bootstrap-1b-sql.ps1
# PART 1B: SQL files (claim, janitor, releases, old-fairness experiment) + TS runner.
# PowerShell 5.1, ASCII only, idempotent.
# Run from: C:\Users\Apple\webhook-gateway
# Precondition: PART 1A has been run; containers are healthy; migrations NOT yet run.

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

# ---- 1. sql/claim.sql (verbatim M1) ----
W 'sql\claim.sql' @'
-- Claim batch. Per-tenant fairness cap is the LATERAL LIMIT 2; batch fill is LIMIT 10.
-- No join to endpoints (C7): disabled endpoints' pending rows are moved to 'paused'
-- by the disable transaction; they are not selected here.
-- Per-row lease_token (D2). Batch processed concurrently by the worker (D3).
-- Claim increments attempts (budget) and total_attempts (C2).
WITH active_tenants AS MATERIALIZED (
  SELECT DISTINCT tenant_id
  FROM deliveries
  WHERE (status = 'pending'    AND next_attempt_at <= now())
     OR (status = 'processing' AND locked_until   <  now())
),
candidates AS MATERIALIZED (
  SELECT d.id, d.next_attempt_at
  FROM active_tenants at
  CROSS JOIN LATERAL (
    SELECT d.id, d.next_attempt_at
    FROM deliveries d
    WHERE d.tenant_id = at.tenant_id
      AND (
        (d.status = 'pending'
          AND d.next_attempt_at <= now()
          AND d.attempts < d.max_attempts)
        OR
        (d.status = 'processing'
          AND d.locked_until < now()
          AND d.attempts <= d.max_attempts           -- D4: recovery send at budget edge
          AND d.reclaim_count < 3)
      )
    ORDER BY d.next_attempt_at, d.id
    LIMIT 2                                          -- per-tenant cap (C6)
    FOR UPDATE SKIP LOCKED
  ) d
),
picked AS (
  SELECT id FROM candidates ORDER BY next_attempt_at, id LIMIT 10
)
UPDATE deliveries d
SET status         = 'processing',
    lease_token    = gen_random_uuid(),
    locked_until   = now() + interval '30 seconds',
    attempts       = d.attempts + 1,
    total_attempts = d.total_attempts + 1,           -- C2
    reclaim_count  = d.reclaim_count
                     + CASE WHEN d.status = 'processing' THEN 1 ELSE 0 END,
    updated_at     = now()
FROM picked p
WHERE d.id = p.id
RETURNING d.id, d.lease_token, d.event_id, d.endpoint_id, d.tenant_id,
          d.attempts, d.total_attempts, d.max_attempts, d.reclaim_count;
'@

# ---- 2. sql/janitor.sql (verbatim M1) ----
W 'sql\janitor.sql' @'
-- C1: also catch stuck 'processing' rows whose attempts already exceeded the budget
-- (claim-time increment on a reclaim at the budget edge made attempts > max_attempts,
-- but the row was never result-written and never meets reclaim_count >= 3).
UPDATE deliveries
SET status       = 'dlq',
    last_error   = COALESCE(last_error, 'janitor: stuck row'),
    lease_token  = NULL,
    locked_until = NULL,
    updated_at   = now()
WHERE status = 'processing'
  AND locked_until < now()
  AND (reclaim_count >= 3 OR attempts > max_attempts)
RETURNING id;
'@

# ---- 3. sql/release_breaker.sql (verbatim M1) ----
W 'sql\release_breaker.sql' @'
-- Breaker-open release: no send occurred, so no delivery_attempts row is written.
-- C2: decrement BOTH attempts (budget) and total_attempts (attempt_number counter),
--     because the claim-time increment did not correspond to a delivery_attempts row.
-- C8: the decrement is safe because the write is fenced by lease_token. Only the
--     worker holding this exact token can match (id, lease_token); no concurrent
--     writer can decrement the same counter for this claim. A stale worker whose
--     lease expired and was taken over writes with its OLD token and gets 0 rows.
-- C8: this gap in attempts is NOT a marker for an ambiguous send. It is simply the
--     undo of the claim-time increment.
UPDATE deliveries
SET status          = 'pending',
    attempts        = attempts - 1,
    total_attempts  = total_attempts - 1,
    locked_until    = NULL,
    lease_token     = NULL,
    next_attempt_at = now() + interval '30 seconds',
    updated_at      = now()
WHERE id = $1 AND lease_token = $2;
'@

# ---- 4. sql/release_shutdown.sql (verbatim M1) ----
W 'sql\release_shutdown.sql' @'
-- Graceful-shutdown release. Same fencing rationale as release_breaker.sql.
-- If the process reaches here after the grace period, the send may or may not have
-- happened. We accept the duplicate exposure (at-least-once). No delivery_attempts
-- row is inserted. C2: decrement attempts and total_attempts.
UPDATE deliveries
SET status          = 'pending',
    attempts        = attempts - 1,
    total_attempts  = total_attempts - 1,
    locked_until    = NULL,
    lease_token     = NULL,
    next_attempt_at = now(),
    updated_at      = now()
WHERE id = $1 AND lease_token = $2;
'@

# ---- 5. sql/_experiments/claim_old_fairness.sql ----
# Pre-C6 fairness mechanism: global ORDER BY next_attempt_at LIMIT 50, THEN per-tenant
# row_number cap. If one tenant has an older backlog larger than 50, its rows fill the
# whole candidate window and other tenants never enter it, so the cap cannot recover
# them. Same SET and RETURNING as sql/claim.sql, so the noisy-neighbor test can be
# run against either query and the diff is attributable only to fairness.
W 'sql\_experiments\claim_old_fairness.sql' @'
-- OLD fairness query (pre-C6). Kept ONLY as an experiment to demonstrate the
-- noisy-neighbor defect. Same SET and RETURNING as sql/claim.sql.
-- Defect: global ORDER BY next_attempt_at LIMIT 50 + per-tenant cap AFTER the fact.
-- A tenant with an older backlog larger than 50 fills the whole window; other
-- tenants never appear in `locked`, so `row_number() <= 2` cannot recover them.
WITH locked AS MATERIALIZED (
  SELECT d.id, d.tenant_id, d.next_attempt_at
  FROM deliveries d
  WHERE (
      (d.status = 'pending'
        AND d.next_attempt_at <= now()
        AND d.attempts < d.max_attempts)
      OR
      (d.status = 'processing'
        AND d.locked_until < now()
        AND d.attempts <= d.max_attempts
        AND d.reclaim_count < 3)
    )
  ORDER BY d.next_attempt_at, d.id
  LIMIT 50
  FOR UPDATE OF d SKIP LOCKED
),
ranked AS (
  SELECT id, tenant_id,
         row_number() OVER (PARTITION BY tenant_id ORDER BY next_attempt_at, id) AS rn
  FROM locked
),
picked AS (
  SELECT id FROM ranked WHERE rn <= 2 ORDER BY id LIMIT 10
)
UPDATE deliveries d
SET status         = 'processing',
    lease_token    = gen_random_uuid(),
    locked_until   = now() + interval '30 seconds',
    attempts       = d.attempts + 1,
    total_attempts = d.total_attempts + 1,
    reclaim_count  = d.reclaim_count
                     + CASE WHEN d.status = 'processing' THEN 1 ELSE 0 END,
    updated_at     = now()
FROM picked p
WHERE d.id = p.id
RETURNING d.id, d.lease_token, d.event_id, d.endpoint_id, d.tenant_id,
          d.attempts, d.total_attempts, d.max_attempts, d.reclaim_count;
'@

# ---- 6. src/db/migrate.ts ----
# host 127.0.0.1 (localhost may resolve to ::1 on Windows [V]); port 5433 with PGPORT
# override; database webhooks; user postgres; password PGPASSWORD default postgres.
W 'src\db\migrate.ts' @'
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';

const MIGRATIONS_DIR = join(__dirname, '../../db/migrations');
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 5433;
const DEFAULT_DB = 'webhooks';
const DEFAULT_USER = 'postgres';
const DEFAULT_PASSWORD = 'postgres';

export async function migrate(dbName: string): Promise<void> {
  const client = new Client({
    host: DEFAULT_HOST,
    port: Number(process.env.PGPORT ?? DEFAULT_PORT),
    user: DEFAULT_USER,
    password: process.env.PGPASSWORD ?? DEFAULT_PASSWORD,
    database: dbName,
  });
  await client.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS _migrations (
        name text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`);
    const applied = new Set(
      (await client.query<{ name: string }>('SELECT name FROM _migrations')).rows.map(r => r.name),
    );
    for (const file of readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort()) {
      if (applied.has(file)) continue;
      const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO _migrations (name) VALUES ($1)', [file]);
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`migration ${file} failed: ${(err as Error).message}`);
      }
    }
  } finally {
    await client.end();
  }
}

if (require.main === module) {
  migrate(process.env.PGDATABASE ?? DEFAULT_DB).catch(err => {
    console.error(err);
    process.exit(1);
  });
}
'@

# ---- 7. src/db/tx.ts ----
W 'src\db\tx.ts' @'
import { Client } from 'pg';

/** C3: SET LOCAL cannot take bind parameters. Use set_config with is_local=true. */
export async function withTenant<T>(
  c: Client, tenantId: string, fn: () => Promise<T>,
): Promise<T> {
  await c.query('BEGIN');
  try {
    await c.query(`SELECT set_config('app.tenant_id', $1, true)`, [tenantId]);
    const out = await fn();
    await c.query('COMMIT');
    return out;
  } catch (err) {
    await c.query('ROLLBACK');
    throw err;
  }
}
'@

Write-Host ''
Write-Host 'Next commands:'
Write-Host "  `$env:PGPORT='5433'"
Write-Host '  npm run migrate'
Write-Host '  Get-ChildItem db\migrations'
Write-Host '  docker exec wg_postgres psql -U postgres -d webhooks -c "\dt"'
Write-Host '  docker exec wg_postgres psql -U postgres -d webhooks -c "\du"'
Write-Host ''
Write-Host 'Expected after migrate:'
Write-Host '  db\migrations contains exactly 2 files: 001_schema.sql, 002_grants.sql'
Write-Host '  \dt shows 9 tables: tenants, api_keys, endpoints, endpoint_secrets, subscriptions,'
Write-Host '                      events, deliveries, delivery_attempts, _migrations'
Write-Host '  \du shows roles postgres plus webhook_api, webhook_dispatcher, webhook_admin, webhook_auth'