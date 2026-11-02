# webhook-gateway

A PostgreSQL-backed webhook delivery queue core. The queue logic is written as plain SQL and tested with TypeScript integration tests against a real PostgreSQL instance.

> **There is no HTTP dispatcher.** Nothing in this repository sends a webhook. It contains the queue state transitions and the tests and mutation harness that verify them.

## What this is, and what it is not

| This is | This is not |
|---|---|
| Four SQL primitives that claim, expire, and release delivery rows | A delivery system: no HTTP transport, signing, timeouts, or response handling |
| Row-level locking plus lease-token fencing inside one database | Distributed locking, consensus, or multi-node coordination |
| Integration tests plus a 43-mutant SQL mutation harness | A benchmarked system: no performance or crash-under-load measurements exist |

## Contents

- [State machine and SQL primitives](#state-machine-and-sql-primitives)
- [Concurrency and isolation](#concurrency-and-isolation)
- [Mutation testing](#mutation-testing)
- [Findings from building the harness](#findings-from-building-the-harness)
- [Current scope and limitations](#current-scope-and-limitations)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Roadmap](#roadmap)
- [License](#license)

## State machine and SQL primitives

Row statuses in the schema: `pending`, `processing`, `paused`, `dlq`, `delivered`.

Only the transitions below are performed by SQL in this repository. No primitive here writes `delivered` or `paused`; `claim.sql` is verified not to claim `paused` rows.
<!-- VERIFY: run Select-String -Path sql\*.sql -Pattern "delivered|paused" and confirm no file writes these statuses -->

```mermaid
stateDiagram-v2
    [*] --> pending
    pending --> processing : claim.sql
    processing --> processing : claim.sql (expired lease reclaimed)
    processing --> pending : release_breaker.sql / release_shutdown.sql
    processing --> dlq : janitor.sql
```

| File | Behavior |
|---|---|
| `sql/claim.sql` | Selects due `pending` rows and `processing` rows whose lease has expired. Sets `processing`, writes a new `lease_token` and `locked_until`, increments `attempts` and `total_attempts`, and increments `reclaim_count` on a reclaim. |
| `sql/janitor.sql` | Moves `processing` rows with an expired lock to `dlq` when `reclaim_count >= 3` or `attempts > max_attempts`. Clears the lease fields and keeps an existing `last_error` (`COALESCE`). |
| `sql/release_breaker.sql` | Undoes a claim: decrements `attempts` and `total_attempts`, clears the lease, returns the row to `pending`, and sets `next_attempt_at` 30 seconds ahead. No attempt row is recorded. Fenced by `lease_token`. |
| `sql/release_shutdown.sql` | The same undo, except the row is claimable again immediately. Fenced by `lease_token`. |

Parameters encoded in `claim.sql`: batch size 10, at most 2 rows per tenant per batch, 30-second lock window, reclaim bound 3. Selection is oldest-first, both across tenants and within a tenant; the per-tenant cap is implemented with a `LATERAL` subquery.

## Concurrency and isolation

Everything here is scoped to **one PostgreSQL database**. The mechanisms and the tests that verify them:

| Mechanism | What it guarantees | Verified by |
|---|---|---|
| `FOR UPDATE SKIP LOCKED` in `claim.sql` | Two concurrent claimers receive disjoint row sets; rollback restores state | `INV-RC-1`, `INV-RC-2` |
| `lease_token` fence in both release files | A wrong or stale token affects 0 rows; a second release with the same token does not decrement twice | `INV-RB-2`, `INV-RB-3`, `INV-RB-4`, `INV-RS-2`, `INV-RS-3` |
| Lease expiry and bounded reclaim | An expired row is reclaimed with a new token; after the bound, `janitor.sql` moves it to `dlq` | `INV-CR-1`, `INV-CR-3`, `INV-CR-4` |
| Per-tenant cap | Batch limit 10, no tenant more than twice, backlog drains in bounded calls | `INV-CL-3`, `INV-CL-4` |

This is not distributed locking. There is no cross-database or cross-node coordination and no external lock service.

## Mutation testing

`mutation-check.ps1` copies one SQL file, applies a single hand-written change (a mutant), runs the test suites, and records the result. A mutant is **killed** only if a test fails. Invalid SQL, errors, and timeouts are reported separately and never counted as kills. The script also hashes the production SQL files before and after the run.

Latest full run: git `7e3f684`, PostgreSQL on port 5433, 2026-10-31, 24.4 minutes.

| Item | Result |
|---|---|
| Baseline | PASS: 1 todo, 37 passed, 38 total |
| Mutants run | 43 |
| Behavioral mutants killed | **40 / 40** |
| Exploratory probes survived | 3 (C19, C20, C21) |
| INVALID / ERROR / TIMEOUT | 0 / 0 / 0 |
| Production SQL | SHA-256 identical before and after |

Behavioral mutants per file: `claim.sql` 18, `janitor.sql` 9, `release_breaker.sql` 7, `release_shutdown.sql` 6. The harness also reports 40/43 = 93% overall; that figure counts the three probes, which are not behavioral mutants. The two numbers come from the same run.

### Surviving probes

| ID | Change to `claim.sql` | Why it survives |
|---|---|---|
| C19 | `LATERAL` due check loosened by 1 hour | No test puts a not-yet-due `pending` row in the same tenant as a due one |
| C20 | `updated_at` not touched by the claim | `updated_at` is not asserted anywhere |
| C21 | `RETURNING` drops `total_attempts` | The `RETURNING` column list is not asserted |

### What these results do not show

- The mutants are finite and hand-written. 40/40 means these 40 changes are detected, not that the SQL is correct.
- Only the four SQL files are mutated. Schema, grants, and TypeScript helpers are not.
- A killed mutant shows a test fails; it does not show the test asserts the right thing.

Full report: [`docs/mutation-report-full.txt`](docs/mutation-report-full.txt), [`docs/mutation-report-full.json`](docs/mutation-report-full.json).

## Findings from building the harness

<!-- VERIFY: confirm each item below matches your own notes before publishing -->
- **Two false kills.** Two mutants first appeared as killed because the mutated SQL was invalid and the tests failed on the SQL error, not on behavior. The harness now classifies these as `INVALID` and excludes them from the kill count.
- **A fairness test that failed on the first query.** The first version of the claim query failed the per-tenant fairness tests. The replacement passes them. The earlier query is kept in `sql/_experiments/claim_old_fairness.sql`.
- **Surviving probes drive the next tests.** C19, C20, and C21 point to assertions that do not exist yet; see [Roadmap](#roadmap).

## Current scope and limitations

- No HTTP dispatcher, transport layer, request signing, or response handling.
- No SQL that records delivery success or failure.
- No redrive path and no endpoint disabling.
- No performance measurements and no `kill -9` crash test during sending.
- Single PostgreSQL instance. Replication and failover are not tested.
- Credentials in this repository are local-development defaults only.

## Repository layout

```text
db/
  init/00-roles.sql         roles created at container init
  migrations/               001_schema.sql, 002_grants.sql
docs/                       full mutation report (txt, json)
scripts/bootstrap/          historical PowerShell bootstrap scripts
sql/
  claim.sql
  janitor.sql
  release_breaker.sql
  release_shutdown.sql
  _experiments/             superseded claim query, kept for reference
src/db/                     migration runner, transaction helper
tests/
  fixtures/  helpers/       seed and snapshot helpers
  integration/              one suite per primitive area
docker-compose.yml
mutation-check.ps1          mutation harness
jest.config.js  tsconfig.json  package.json
```

`sql/_mutants/` is generated by the harness and is git-ignored. The Compose file also starts a Redis container (`wg_redis`); the SQL core does not use it.

## Quick start

Requirements: Node.js, Docker with Compose, PowerShell (the mutation harness is a PowerShell script).

```powershell
git clone https://github.com/mohammed-dev-stack/webhook-gateway.git
cd webhook-gateway
npm install
docker compose up -d --wait
```

Point the tests at the database. The credentials are local defaults; do not reuse them elsewhere.

```powershell
$env:DATABASE_URL = "postgres://postgres:postgres@127.0.0.1:5433/webhooks"
$env:PGPORT = "5433"
```

<!-- VERIFY: published host port in docker-compose.yml (5433 was used in the last run) -->
<!-- VERIFY: migration command (src/db/migrate.ts exists; confirm the package.json script or whether tests migrate their own databases) -->

Run the tests:

```powershell
npm test
```

Run the mutation harness (about 25 minutes for 43 mutants):

```powershell
powershell -ExecutionPolicy Bypass -File .\mutation-check.ps1
```

Drop leftover `whtest_*` databases from an interrupted run:

```powershell
.\mutation-check.ps1 -CleanOrphans -ContainerName wg_postgres
```

## Roadmap

Intentions, in no fixed order:

1. Tests for the three surviving probes (C19, C20, C21), then re-run the harness.
2. SQL for recording delivery success and failure, with redrive and endpoint disabling.
3. A dispatcher, with a crash-recovery test that kills the process mid-send.
4. A first measured benchmark, published with the hardware it ran on.

## License
