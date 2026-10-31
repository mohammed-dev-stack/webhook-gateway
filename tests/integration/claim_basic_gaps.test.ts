/**
 * claim_basic_gaps.test.ts
 *
 * Closes three surviving SQL mutants (C15, C16, C17) by creating the
 * preconditions that each mutation violates.
 *
 * SEEDING STRATEGY
 * ----------------
 * `deliveries` has a UNIQUE constraint on (event_id, endpoint_id) AND FKs
 * pointing at endpoints/events. Both are bypassed/avoided at the same time:
 *
 *  1. `SET session_replication_role = 'replica'` on the per-test connection
 *     disables FK triggers (the technique `pg_restore` uses). Parent rows
 *     (endpoints / events / tenants) never need to exist.
 *
 *  2. `freshFkValue()` generates a UNIQUE pair per inserted row, satisfying
 *     the UNIQUE(event_id, endpoint_id) constraint. UUID columns receive
 *     `randomUUID()`; integer columns receive an incrementing counter that
 *     cannot collide with TRUNCATEd rows.
 *
 * The session role is reset to 'origin' in a `finally` block so the
 * connection is never left in a relaxed state.
 *
 * UUID DISCIPLINE
 * ---------------
 * Every fixture value that maps to a `uuid` column is a canonical
 * 8-4-4-4-12 v4 UUID (version nibble '4', variant in [8,9,a,b]), so it
 * stays valid under a strict RFC 4122 CHECK constraint.
 */

import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import * as fs from 'fs';
import path from 'path';

const connectionString =
  process.env.DATABASE_URL ||
  'postgres://postgres:postgres@127.0.0.1:5432/webhooks';

const CLAIM_SQL_PATH = process.env.CLAIM_SQL_FILE || 'sql/claim.sql';
const CLAIM_SQL = fs.readFileSync(path.resolve(CLAIM_SQL_PATH), 'utf8');

let pool: Pool;
let endpointIdType: string | null = null;
let eventIdType: string | null = null;

// Monotonic counter for integer-typed FK columns. Safe because TRUNCATE
// RESTART IDENTITY runs before each test, so no live row can ever collide.
let fkCounter = 1_000_000_000;

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
  nextAttemptAgoMs?: number;
  lockedUntilAgoMs?: number | null;
  attempts?: number;
  maxAttempts?: number;
  totalAttempts?: number;
  reclaimCount?: number;
  leaseToken?: string | null;
  endpointId?: string | number;
  eventId?: string | number;
}

function freshFkValue(type: string | null): string | number {
  if (type === 'integer' || type === 'bigint' || type === 'smallint') {
    return ++fkCounter;
  }
  // uuid / text / varchar / bpchar / etc. — all accept a UUID string.
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

    // Unique pair per row — satisfies UNIQUE(event_id, endpoint_id).
    const endpointValue = args.endpointId ?? freshFkValue(endpointIdType);
    const eventValue    = args.eventId    ?? freshFkValue(eventIdType);

    const now = Date.now();
    const nextAttempt = new Date(now - (args.nextAttemptAgoMs ?? 60_000));
    const lockedUntil =
      args.lockedUntilAgoMs == null
        ? null
        : new Date(now - args.lockedUntilAgoMs);

    const r = await client.query(
      `INSERT INTO deliveries
          (tenant_id, status, next_attempt_at, locked_until,
           attempts, max_attempts, total_attempts, reclaim_count,
           lease_token, endpoint_id, event_id)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       RETURNING id`,
      [
        args.tenantId,
        args.status,
        nextAttempt,
        lockedUntil,
        args.attempts      ?? 0,
        args.maxAttempts   ?? 5,
        args.totalAttempts ?? 0,
        args.reclaimCount  ?? 0,
        args.leaseToken    ?? null,
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

describe('claim_basic_gaps', () => {
  test('C15: paused rows are not claimable even when due in the same tenant as a pending due row', async () => {
    const tenant = '11111111-1111-4111-a111-111111111115';
    const pendingId = await seedDelivery({
      tenantId: tenant, status: 'pending', nextAttemptAgoMs: 60_000,
    });
    const pausedId = await seedDelivery({
      tenantId: tenant, status: 'paused',  nextAttemptAgoMs: 60_000,
    });

    const result = await pool.query(CLAIM_SQL);
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0].id).toBe(pendingId);

    const pausedRow = await pool.query(
      'SELECT status FROM deliveries WHERE id = $1', [pausedId]);
    expect(pausedRow.rows[0].status).toBe('paused');

    const pendingRow = await pool.query(
      'SELECT status FROM deliveries WHERE id = $1', [pendingId]);
    expect(pendingRow.rows[0].status).toBe('processing');
  });

  test('C16: outer claim picks the OLDEST 10 across tenants, not the 10 lowest ids', async () => {
    const rows: { id: number; ageMin: number }[] = [];
    for (let i = 0; i < 20; i++) {
      const tenantHex = String((i % 10) + 1).padStart(12, '0');
      const tenant = `22222222-2222-4222-a222-${tenantHex}`;
      const ageMin = i + 1;
      const id = await seedDelivery({
        tenantId: tenant,
        status: 'pending',
        nextAttemptAgoMs: ageMin * 60_000,
      });
      rows.push({ id, ageMin });
    }

    const result = await pool.query(CLAIM_SQL);
    expect(result.rows).toHaveLength(10);

    const claimedIds  = new Set<number>(result.rows.map((r: any) => r.id));
    const claimedAges = rows
      .filter((r) => claimedIds.has(r.id))
      .map((r) => r.ageMin)
      .sort((a, b) => a - b);

    expect(claimedAges).toEqual([11, 12, 13, 14, 15, 16, 17, 18, 19, 20]);

    const mutantAgesIfBugPresent = rows.slice(0, 10).map((r) => r.ageMin);
    expect(claimedAges).not.toEqual(mutantAgesIfBugPresent);
  });

  test('C17: LATERAL picks the OLDEST 2 within a tenant, not the 2 lowest ids', async () => {
    const tenant = '33333333-3333-4333-a333-333333333317';
    const rows: { id: number; ageMin: number }[] = [];
    for (let i = 0; i < 5; i++) {
      const ageMin = i + 1;
      const id = await seedDelivery({
        tenantId: tenant,
        status: 'pending',
        nextAttemptAgoMs: ageMin * 60_000,
      });
      rows.push({ id, ageMin });
    }

    const result = await pool.query(CLAIM_SQL);
    expect(result.rows).toHaveLength(2);

    const claimedIds  = new Set<number>(result.rows.map((r: any) => r.id));
    const claimedAges = rows
      .filter((r) => claimedIds.has(r.id))
      .map((r) => r.ageMin)
      .sort((a, b) => a - b);

    expect(claimedAges).toEqual([4, 5]);

    const mutantAgesIfBugPresent = rows.slice(0, 2).map((r) => r.ageMin);
    expect(claimedAges).not.toEqual(mutantAgesIfBugPresent);
  });
});