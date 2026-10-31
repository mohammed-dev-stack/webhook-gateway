/**
 * janitor_gaps.test.ts
 *
 * Closes two surviving SQL mutants (J05, J08) in the janitor query.
 *
 *  - J05 requires the pre-janitor row to have a REAL, NON-NULL lease_token,
 *    otherwise clearing it is unobservable.
 *  - J08 requires a 'pending' row that matches every other WHERE clause
 *    (expired lock, exceeded counters) so that only `status = 'processing'`
 *    protects it from being moved to 'dlq'.
 *
 * Seeding strategy: identical to claim_basic_gaps.test.ts — FK triggers are
 * disabled per-session via `session_replication_role = 'replica'`, and each
 * row receives a fresh (event_id, endpoint_id) pair to satisfy the UNIQUE
 * constraint. No parent rows are ever inserted.
 */

import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import * as fs from 'fs';
import path from 'path';

const connectionString =
  process.env.DATABASE_URL ||
  'postgres://postgres:postgres@127.0.0.1:5432/webhooks';

const JANITOR_SQL_PATH = process.env.JANITOR_SQL_FILE || 'sql/janitor.sql';
const JANITOR_SQL = fs.readFileSync(path.resolve(JANITOR_SQL_PATH), 'utf8');

// Named fixture UUIDs (single audit point for the "must be valid uuid" rule).
const TENANT_J05            = '55555555-5555-4555-a555-555555555505';
const TENANT_J08            = '88888888-8888-4888-a888-888888888808';
const LEASE_J05_STALE       = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const LEASE_J08_PENDING     = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const LEASE_J08_PROCESSING  = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const LAST_ERROR_SENTINEL   = 'sentinel-before';

let pool: Pool;
let endpointIdType: string | null = null;
let eventIdType: string | null = null;

let fkCounter = 2_000_000_000; // offset from claim_basic_gaps' counter

beforeAll(async () => {
  pool = new Pool({ connectionString });
  const r = await pool.query(
    `SELECT column_name, data_type
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'deliveries'
        AND column_name IN ('endpoint_id', 'event_id')`,
  );
  for (const row of r.rows) {
    if (row.column_name === 'endpoint_id') endpointIdType = row.data_type;
    if (row.column_name === 'event_id')    eventIdType    = row.data_type;
  }
});

afterAll(async () => {
  await pool.end();
});

beforeEach(async () => {
  await pool.query('TRUNCATE TABLE deliveries RESTART IDENTITY CASCADE;');
});

// ---------------------------------------------------------------------------
// Seeder
// ---------------------------------------------------------------------------

interface SeedDeliveryArgs {
  tenantId: string;
  status: 'pending' | 'processing' | 'paused' | 'dlq' | 'delivered';
  lockedUntilAgoMs?: number | null;
  attempts?: number;
  maxAttempts?: number;
  totalAttempts?: number;
  reclaimCount?: number;
  leaseToken?: string | null;
  lastError?: string | null;
  endpointId?: string | number;
  eventId?: string | number;
}

function freshFkValue(type: string | null): string | number {
  if (type === 'integer' || type === 'bigint' || type === 'smallint') {
    return ++fkCounter;
  }
  return randomUUID();
}

async function seedDelivery(args: SeedDeliveryArgs): Promise<number> {
  const client = await pool.connect();
  try {
    try {
      await client.query("SET session_replication_role = 'replica'");
    } catch (e: any) {
      throw new Error(
        'Could not set session_replication_role = replica; the test DB user ' +
        'must be a superuser (postgres:postgres satisfies this). ' +
        'Underlying error: ' + (e?.message ?? String(e)),
      );
    }

    const endpointValue = args.endpointId ?? freshFkValue(endpointIdType);
    const eventValue    = args.eventId    ?? freshFkValue(eventIdType);

    const now = Date.now();
    const lockedUntil =
      args.lockedUntilAgoMs == null
        ? null
        : new Date(now - args.lockedUntilAgoMs);

    const r = await client.query(
      `INSERT INTO deliveries
          (tenant_id, status, next_attempt_at, locked_until,
           attempts, max_attempts, total_attempts, reclaim_count,
           lease_token, last_error, endpoint_id, event_id)
       VALUES ($1,$2,now(),$3,$4,$5,$6,$7,$8,$9,$10,$11)
       RETURNING id`,
      [
        args.tenantId,
        args.status,
        lockedUntil,
        args.attempts      ?? 0,
        args.maxAttempts   ?? 5,
        args.totalAttempts ?? 0,
        args.reclaimCount  ?? 0,
        args.leaseToken    ?? null,
        args.lastError     ?? null,
        endpointValue,
        eventValue,
      ],
    );
    return r.rows[0].id as number;
  } finally {
    try {
      await client.query("SET session_replication_role = 'origin'");
    } catch { /* connection is released anyway */ }
    client.release();
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('janitor_gaps', () => {
  test('J05: janitor clears lease_token on a stuck processing row', async () => {
    const id = await seedDelivery({
      tenantId: TENANT_J05,
      status: 'processing',
      lockedUntilAgoMs: 3_600_000,
      attempts: 10,
      maxAttempts: 5,
      totalAttempts: 10,
      reclaimCount: 3,
      leaseToken: LEASE_J05_STALE,
    });

    const before = await pool.query(
      'SELECT lease_token, status FROM deliveries WHERE id = $1', [id]);
    expect(before.rows[0].lease_token).toBe(LEASE_J05_STALE);
    expect(before.rows[0].status).toBe('processing');

    await pool.query(JANITOR_SQL);

    const after = await pool.query(
      'SELECT lease_token, status, last_error FROM deliveries WHERE id = $1',
      [id]);
    expect(after.rows[0].lease_token).toBeNull();
    expect(after.rows[0].status).toBe('dlq');
    expect(after.rows[0].last_error).toBeTruthy();
  });

  test('J08: janitor does not touch a pending row with an expired lock and exceeded counters', async () => {
    const pendingId = await seedDelivery({
      tenantId: TENANT_J08,
      status: 'pending',
      lockedUntilAgoMs: 3_600_000,
      attempts: 10,
      maxAttempts: 5,
      totalAttempts: 10,
      reclaimCount: 3,
      leaseToken: LEASE_J08_PENDING,
      lastError: LAST_ERROR_SENTINEL,
    });

    const processingId = await seedDelivery({
      tenantId: TENANT_J08,
      status: 'processing',
      lockedUntilAgoMs: 3_600_000,
      attempts: 10,
      maxAttempts: 5,
      totalAttempts: 10,
      reclaimCount: 3,
      leaseToken: LEASE_J08_PROCESSING,
    });

    await pool.query(JANITOR_SQL);

    const pendingAfter = await pool.query(
      'SELECT status, lease_token, last_error FROM deliveries WHERE id = $1',
      [pendingId]);
    expect(pendingAfter.rows[0].status).toBe('pending');
    expect(pendingAfter.rows[0].lease_token).toBe(LEASE_J08_PENDING);
    expect(pendingAfter.rows[0].last_error).toBe(LAST_ERROR_SENTINEL);

    const processingAfter = await pool.query(
      'SELECT status, lease_token FROM deliveries WHERE id = $1',
      [processingId]);
    expect(processingAfter.rows[0].status).toBe('dlq');
    expect(processingAfter.rows[0].lease_token).toBeNull();
  });
});