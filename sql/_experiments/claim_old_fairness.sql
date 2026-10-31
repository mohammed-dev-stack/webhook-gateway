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