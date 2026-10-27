# Architecture decision records

Daravel's design decisions are recorded as ADRs in the maintainer's design
documents, which are not public. Code comments refer to them by number
(`ADR-003`, `ADR-024`, ...). The records in this folder make the decisions
the running code depends on readable without those documents.

Each record here was **reconstructed from the code and its comments** on
2026-10-27 and is marked for the maintainer's review: it says what the code
does and why its comments say it does so, and nothing the code does not
show. Where a record and the code disagree, the code is right and the
record is a bug.

| ADR | Decision |
| :-- | :-- |
| [ADR-003](0003-state-scopes.md) | State scopes: `isolate`, `process` (the coordinator) and `cluster`; rate-limit leases |
| [ADR-004](0004-supervisor-and-workers.md) | A supervisor isolate, N worker isolates on one port, and the coordinator |
| [ADR-024](0024-laravel-coexistence-defaults.md) | Laravel's defaults for `Crypt` (AES-256-CBC) and hashing (bcrypt) |
