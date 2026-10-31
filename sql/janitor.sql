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