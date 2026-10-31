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