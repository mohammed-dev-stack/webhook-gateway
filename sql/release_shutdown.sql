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