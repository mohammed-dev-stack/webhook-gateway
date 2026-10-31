# Webhook Gateway & Fault-Tolerant Dispatcher Engine

A production-grade, highly reliable, and deterministic webhook delivery queue engineered with PostgreSQL and Node.js, featuring strict concurrency controls (`FOR UPDATE SKIP LOCKED`) and a rigorous mutation-testing harness.

## Architecture Highlights
- **Deterministic State Machine:** Explicit status transitions managed via pure SQL.
- **Concurrency Safety:** Distributed locking and row-level locking to prevent race conditions.
- **Mutation Tested:** Verified against 43 semantic SQL mutants with a 93% mutation score (40/40 behavioral mutants killed).

## Quick Start
1. Start infrastructure: `docker compose up -d --wait`
2. Run test suites: `npm test`
3. Run mutation harness: `powershell -ExecutionPolicy Bypass -File .\mutation-check.ps1`
