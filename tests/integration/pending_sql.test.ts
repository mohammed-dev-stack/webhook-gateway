// Production SQL files that the dispatcher needs but do not exist yet.
// Tracked as test.todo so the count of pending capabilities is visible in Jest output.
// When the corresponding SQL file is written, replace each todo with a real test.

test.todo('TODO FENCED-SUCCESS: fenced success write (not yet in production SQL)');
test.todo('TODO FENCED-RETRY: fenced retryable-failure write (not yet in production SQL)');
test.todo('TODO FENCED-PERM: fenced permanent-failure write (not yet in production SQL)');
test.todo('TODO REDRIVE: redrive (not yet in production SQL)');
test.todo('TODO ENDPOINT-DISABLE: endpoint disable/enable (not yet in production SQL)');