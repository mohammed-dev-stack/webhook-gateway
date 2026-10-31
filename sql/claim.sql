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