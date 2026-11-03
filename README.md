# webhook-gateway

A PostgreSQL-backed webhook delivery queue core: SQL primitives for claiming, recovering and releasing deliveries, with an integration test suite and a mutation-testing harness.

**There is no dispatcher yet.** Nothing in this repository sends an HTTP request, signs a payload, or schedules a retry. What exists is the queue's database layer and the tests that pin its behaviour.

- Languages: SQL (PostgreSQL 16) and TypeScript (tests and migration runner).
- Queue storage: PostgreSQL only. No message broker.
- Redis 7 is started by `docker-compose.yml`. Nothing in the code uses it.
- Not a distributed system: all coordination happens inside one PostgreSQL instance.
- Status: work in progress. See [Current scope and limitations](#current-scope-and-limitations).

Provenance: design drafts and test code were produced with LLM assistance, then verified by running the test suite and the mutation harness described below.

## Core primitives and state machine

### Schema

`db/migrations/001_schema.sql` defines eight tables: `tenants`, `api_keys`, `endpoints`, `endpoint_secrets`, `subscriptions`, `events`, `deliveries`, `delivery_attempts`. Row-level security is enabled and forced on six of them (`tenants`, `endpoints`, `endpoint_secrets`, `subscriptions`, `events`, `deliveries`). `db/init/00-roles.sql` creates four roles (`webhook_api`, `webhook_dispatcher`, `webhook_admin`, `webhook_auth`); grants are in `db/migrations/002_grants.sql`.

Only `deliveries` is touched by the SQL primitives below. The other tables are schema only: no code reads or writes them outside the test helpers.

### SQL primitives

| File | What it does |
|---|---|
| `sql/claim.sql` | Selects due deliveries and marks them `processing` with a fresh `lease_token`. Returns `id, lease_token, event_id, endpoint_id, tenant_id, attempts, total_attempts, max_attempts, reclaim_count`. |
| `sql/janitor.sql` | Moves stuck `processing` rows to `dlq`. |
| `sql/release_breaker.sql` | Undoes a claim when no send happened (breaker open). Parameters: `$1` delivery id, `$2` lease token. |
| `sql/release_shutdown.sql` | Same undo for graceful shutdown. Parameters: `$1`, `$2`. |
| `sql/_experiments/claim_old_fairness.sql` | The earlier fairness design, kept on purpose to demonstrate its defect. Not used by anything else. |

### Statuses

The `deliveries.status` CHECK constraint allows: `pending`, `processing`, `succeeded`, `dlq`, `paused`.

### Implemented transitions

| From | To | Statement | Details |
|---|---|---|---|
| `pending`, due, `attempts < max_attempts` | `processing` | `claim.sql` | `attempts + 1`, `total_attempts + 1`, new `lease_token`, `locked_until = now() + 30 s`. |
| `processing`, lease expired | `processing` | `claim.sql` (reclaim) | Allowed while `attempts <= max_attempts` and `reclaim_count < 3`. `reclaim_count + 1`, new `lease_token`. |
| `processing`, lease expired, `reclaim_count >= 3` or `attempts > max_attempts` | `dlq` | `janitor.sql` | Clears `lease_token` and `locked_until`; sets `last_error` to `janitor: stuck row` only if it was null. |
| `processing` | `pending` | `release_breaker.sql` | Fenced by `lease_token`. `attempts - 1`, `total_attempts - 1`, `next_attempt_at = now() + 30 s`. |
| `processing` | `pending` | `release_shutdown.sql` | Fenced by `lease_token`. `attempts - 1`, `total_attempts - 1`, `next_attempt_at = now()`. |

### Not implemented

These transitions have no SQL yet (listed as `test.todo` in `tests/integration/pending_sql.test.ts`):

- `processing` -> `succeeded` (fenced success write)
- `processing` -> `pending` with backoff, or -> `dlq` when attempts are exhausted (fenced retryable-failure write)
- `processing` -> `dlq` (fenced permanent-failure write)
- `dlq` -> `pending` (redrive)
- `pending` <-> `paused` (endpoint disable/enable)

`succeeded` and `paused` exist only as allowed values. `claim.sql` never selects them.

### Counters

- `attempts`: retry budget. Intended to be reset by redrive (not implemented).
- `total_attempts`: monotonic. Intended to become `delivery_attempts.attempt_number`. No SQL writes `delivery_attempts` yet.
- The release statements decrement both counters because no attempt row exists for a send that did not happen.

## Concurrency and isolation

All coordination is row-level locking and compare-by-token inside a single PostgreSQL instance. This is not distributed locking.

### How `claim.sql` works

One statement, in four steps:

1. `active_tenants`: distinct tenants having a due `pending` row or an expired `processing` row.
2. `candidates`: for each active tenant, a `CROSS JOIN LATERAL` subquery takes at most 2 rows ordered by `next_attempt_at, id`, with `FOR UPDATE SKIP LOCKED`.
3. `picked`: the oldest 10 candidates across tenants (`ORDER BY next_attempt_at, id LIMIT 10`).
4. `UPDATE ... FROM picked`: sets status, lease token, lock expiry and counters.

Abridged shape of step 2:

```sql
CROSS JOIN LATERAL (
  SELECT d.id, d.next_attempt_at
  FROM deliveries d
  WHERE d.tenant_id = at.tenant_id
    AND ( /* due pending row, or expired processing row within bounds */ )
  ORDER BY d.next_attempt_at, d.id
  LIMIT 2
  FOR UPDATE SKIP LOCKED
) d
```

### Properties

- **Skip, do not wait:** `SKIP LOCKED` sits at the same query level as the per-tenant `LIMIT 2`. A row locked by another transaction is skipped and does not consume the tenant's quota.
- **Surplus locks:** the lateral step can lock up to 2 rows per active tenant while the outer step updates at most 10. Rows locked but not updated stay locked until the surrounding transaction ends. In autocommit that is the end of the statement.
- **Fairness cap:** at most 2 rows per tenant per claim, 10 per claim. Cost: with a single active tenant one claim returns at most 2 rows.
- **Lease:** `lease_token` is a new `gen_random_uuid()` per row per claim. `locked_until = now() + 30 s`. Expiry is evaluated with the database clock. No application clock is read.
- **Fencing:** the release statements use `WHERE id = $1 AND lease_token = $2`. A stale token affects 0 rows and leaves the row unchanged. Success/failure write statements that would use the same fence do not exist yet.
- **Isolation level:** PostgreSQL default (READ COMMITTED). Nothing in this repository changes it.
- **Ordering:** oldest `next_attempt_at` first, within the limits above. No ordering guarantee per endpoint or per event.

### Tested

- Two or more concurrent claims return disjoint row sets (`claim_race`). Those tests set `lock_timeout`, so a claim without `SKIP LOCKED` fails in seconds instead of hanging.
- A tenant with a 1000-row backlog does not starve a tenant with 10 rows (`claim_fairness`). The old query returns rows only from the large tenant (documented in the same suite).
- Reclaim after an expired lease, the `attempts <= max_attempts` edge and the reclaim bound of 3 (`crash_recovery`).
- Stale-token releases change nothing (`release_breaker`, `release_shutdown`).

### Not provided

- Distributed locking, cross-instance coordination, failover handling.
- Exactly-once delivery. At-least-once is the intended semantic, but it cannot be exercised without a dispatcher.

## Mutation testing

### What the harness does

`mutation-check.ps1` applies single-site textual mutations to the four production SQL files and runs the test suites against each mutant. Production files are never modified: each mutant is written to `sql/_mutants/<ID>.sql` (git-ignored) and loaded through test-only environment variables read in `tests/fixtures/sql.ts` (`CLAIM_SQL_FILE`, `JANITOR_SQL_FILE`, `RELEASE_BREAKER_SQL_FILE`, `RELEASE_SHUTDOWN_SQL_FILE`).

For each mutant:

1. **Gate:** the `smoke` suite runs alone. If it fails, the mutant is `INVALID` (the SQL no longer parses, binds or is permitted). That is not a kill.
2. **Domain suites:** the 10 other suites run. Any failing suite means `KILLED`; all passing means `SURVIVED`.
3. Anything else (database unreachable, suite failed to load, incomplete run, timeout) is `ERROR` or `TIMEOUT`, never a kill.

Before generating each mutant the harness checks that its pattern matches exactly once, that the mutation changes the text, and that the source file's SHA-256 has not changed since the run started.

### Recorded result

Report: `docs/mutation-report-full.txt` (and `.json`), recorded at git commit `7e3f684`.

| Result | Count |
|---|---|
| Behavioural mutants killed | **40 of 40** |
| Exploratory probes survived | 3 |
| INVALID / ERROR / TIMEOUT | 0 |

Per file: `claim.sql` 21 mutants (18 behavioural, 3 probes), `janitor.sql` 9, `release_breaker.sql` 7, `release_shutdown.sql` 6.

Mutation classes include: removing `SKIP LOCKED`, changing the per-tenant cap and batch size, off-by-one on the reclaim boundary and bound, not incrementing counters, not clearing or not generating the lease token, shifting lock and backoff windows, ignoring the tenant in the lateral subquery, claiming `paused` rows, ordering by `id` instead of age, removing the `lease_token` fence from the release statements, and weakening each janitor condition. The full per-mutant matrix with the suites that killed each one is in the report.

Integrity check: the harness hashed the four production SQL files (SHA-256) before and after the run. They were identical.

Baseline of the domain suites during the recorded run: 37 passed, 1 todo. The full run took 24.4 minutes on the author's machine.

### Surviving probes

| ID | Mutation | Why it survives | Missing test |
|---|---|---|---|
| C19 | Lateral due check loosened by 1 hour | `active_tenants` already filters to tenants with due rows | A tenant with a due row and a not-yet-due pending row |
| C20 | `claim.sql` stops touching `updated_at` | `updated_at` is not asserted anywhere | Assertion on `updated_at` |
| C21 | `RETURNING` drops `total_attempts` | The returned column list is not asserted | Assertion on the returned columns |

### What this does and does not show

- A kill means at least one test failed. It does not mean a test was written for that mutant.
- Survivors may be behaviourally equivalent mutants. The three probes were not analysed for equivalence.
- Mutants are single-line textual edits on four files. Not covered: schema, RLS policies, grants, TypeScript helpers.
- An earlier version of the harness counted SQL that no longer parsed as kills (two false kills in the release statements). The `smoke` gate and fence-removal mutants that keep the statement valid fixed that.

### Run it

Interactive PowerShell session at the repository root, with Docker Postgres up (see Quick start). Do not run Jest by hand while it runs.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\mutation-check.ps1 -ListOnly
.\mutation-check.ps1 -Inspect -Only C02
.\mutation-check.ps1 -Only C01,B01,S01
.\mutation-check.ps1
.\mutation-check.ps1 -CleanOrphans
```

`-CleanOrphans` drops leftover `whtest_*` databases from the `wg_postgres` container.

Known issues of the harness, as of the recorded run:

- `-SkipBaseline` does not resolve the PostgreSQL port, so the run aborts with exit code 5.
- Every run overwrites `mutation-report.txt` and `mutation-report.json` in the repository root, including `-Only` runs. Copy the full report first (the committed full report is under `docs/`).
- The `-SelfTest` option reports more invariants than can actually fail.

## Current scope and limitations

**No dispatcher yet.** The following do not exist in this repository:

- HTTP transport: no request is ever sent. No SSRF guard, no timeouts, no response handling.
- Request signing, secret encryption or rotation.
- Retry scheduling: no backoff, no jitter. The release statements use fixed delays (`now() + 30 s` and `now()`).
- Circuit breaker and rate limiter: `release_breaker.sql` is only the database-side undo of a claim.
- Ingestion API, event fan-out, idempotency handling, API key authentication. Rows are inserted only by test helpers.
- Any use of Redis.

SQL not written yet: fenced success write, fenced retryable and permanent failure writes, redrive, endpoint disable/enable. Nothing writes `delivery_attempts`.

Test gaps:

- Row-level security behaviour is not tested. The suite checks that RLS is enabled and forced on six tables, that role attributes are as designed, and that `webhook_api` cannot read `api_keys` directly.
- Composite foreign keys, `auth_resolve`, grants beyond that check, and idempotency constraints have no dedicated tests.
- Six `test.todo` entries: five in `pending_sql.test.ts`, one in `crash_recovery.test.ts`.

Open design issues:

- A `processing` row with `NULL locked_until` is never reclaimed by `claim.sql` and never moved by `janitor.sql`. It can only arise from manual SQL; `crash_recovery` has a `test.todo` for it.
- `webhook_api` has no `UPDATE` privilege on `deliveries`, so moving a tenant's pending rows to `paused` with that role would fail. The role used for endpoint disable/enable is undecided.
- Lease duration (30 s), per-tenant cap (2), batch size (10) and reclaim bound (3) are literals inside the SQL, not parameters.
- `active_tenants` scans `deliveries` on every claim. No performance has been measured. There is no benchmark.

Environment:

- Single PostgreSQL instance. No replication, no failover, no durability settings tested.
- Developed and run only on Windows with Docker Desktop and Windows PowerShell 5.1. Nothing has been run on Linux or macOS. The mutation harness is PowerShell-only.

## Repository layout

```text
.
|-- db/
|   |-- init/00-roles.sql            roles, created on first container start
|   `-- migrations/
|       |-- 001_schema.sql
|       `-- 002_grants.sql
|-- docs/
|   |-- mutation-report-full.txt     recorded 43-mutant run
|   `-- mutation-report-full.json
|-- scripts/
|   `-- bootstrap/                   one-off PowerShell generators used to create the original files
|-- sql/
|   |-- claim.sql
|   |-- janitor.sql
|   |-- release_breaker.sql
|   |-- release_shutdown.sql
|   |-- _experiments/claim_old_fairness.sql
|   `-- _mutants/                    generated by mutation-check.ps1, git-ignored
|-- src/db/
|   |-- migrate.ts                   applies db/migrations/*.sql in order
|   `-- tx.ts                        tenant-scoped transaction helper
|-- tests/
|   |-- fixtures/sql.ts              loads the SQL files (with test-only overrides)
|   |-- helpers/                     db.ts, seed.ts, snapshot.ts
|   `-- integration/                 *.test.ts
|-- docker-compose.yml               PostgreSQL 16 and Redis 7
|-- jest.config.js
|-- mutation-check.ps1
|-- package.json
`-- tsconfig.json
```

`scripts/bootstrap/` is a historical record. Those scripts write files relative to their own location, so do not re-run them from that folder.

Test suites (`tests/integration/`):

| Suite | Covers |
|---|---|
| `smoke` | Migrations applied, 9 tables, RLS flags, role attributes, `auth_resolve`, `api_keys` permission, all SQL files execute on an empty database |
| `seed` | The test helpers themselves |
| `claim_basic`, `claim_basic_gaps` | Claim contents, limits, drain, paused/dlq/succeeded exclusion, oldest-first ordering |
| `claim_fairness` | Noisy-neighbour behaviour and the old query's defect |
| `claim_race` | Concurrent claims |
| `crash_recovery` | Reclaim, budget edge, reclaim bound, janitor hand-off |
| `claim_release_cycle`, `release_breaker`, `release_shutdown` | Release statements, stale tokens, counters |
| `janitor`, `janitor_gaps` | Janitor conditions and cleared fields |
| `pending_sql` | `test.todo` entries for the SQL not yet written |

## Quick start and local development

Requirements: Docker Desktop (Compose v2), Node.js and npm (the project pins `@types/node` 20, so Node 20 or later is assumed), Windows PowerShell 5.1 for the mutation harness.

```powershell
git clone https://github.com/mohammed-dev-stack/webhook-gateway.git
cd webhook-gateway
npm install
docker compose up -d --wait
npm test
```

`docker compose up` starts PostgreSQL 16 on host port **5433** (`wg_postgres`) and Redis 7 on **6380** (`wg_redis`). The first start creates the database `webhooks` and the four roles from `db/init/00-roles.sql`.

Every test file creates its own database named `whtest_<timestamp>_<random>`, applies the migrations to it, and drops it afterwards. Applying migrations by hand is only needed if you want the schema in the default `webhooks` database:

```powershell
npm run migrate
```

Run a single suite:

```powershell
npx jest claim_race
```

Connection settings used by the tests and the migration runner:

| Setting | Default | Override |
|---|---|---|
| Host | `127.0.0.1` | none |
| Port | `5433` | `PGPORT` |
| Superuser password | `postgres` | `PGPASSWORD` |

Credentials are for local development only: superuser `postgres` / `postgres`, and roles `webhook_api`, `webhook_dispatcher`, `webhook_admin`, `webhook_auth` with password `change_me`. They are hard-coded in `db/init/00-roles.sql` and `tests/helpers/db.ts`. `docker-compose.yml` publishes ports 5433 and 6380 on all host interfaces, so run it only on a trusted network or restrict the mappings to `127.0.0.1`.

If a run is interrupted and leaves test databases behind:

```powershell
.\mutation-check.ps1 -CleanOrphans
```

To stop and remove the containers and their data:

```powershell
docker compose down -v
```