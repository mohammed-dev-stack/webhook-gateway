import { readFileSync } from 'node:fs';
import { join } from 'node:path';

function readFromCwd(file: string): string {
  return readFileSync(join(process.cwd(), file), 'utf8');
}

export const claimSQL = readFromCwd(
  process.env.CLAIM_SQL_FILE ?? 'sql/claim.sql',
);
export const janitorSQL = readFromCwd(
  process.env.JANITOR_SQL_FILE ?? 'sql/janitor.sql',
);
export const releaseBreakerSQL = readFromCwd(
  process.env.RELEASE_BREAKER_SQL_FILE ?? 'sql/release_breaker.sql',
);
export const releaseShutdownSQL = readFromCwd(
  process.env.RELEASE_SHUTDOWN_SQL_FILE ?? 'sql/release_shutdown.sql',
);
export const claimOldFairnessSQL = readFromCwd(
  'sql/_experiments/claim_old_fairness.sql',
);