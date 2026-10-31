import { Client } from 'pg';

export async function snapshotDeliveries(admin: Client): Promise<string> {
  const r = await admin.query(
    `SELECT id, event_id, endpoint_id, tenant_id, status, attempts, total_attempts,
            max_attempts, reclaim_count, next_attempt_at, locked_until, lease_token,
            last_error, created_at, updated_at
       FROM deliveries
       ORDER BY id`,
  );
  return JSON.stringify(r.rows);
}