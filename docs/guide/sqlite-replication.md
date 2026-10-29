# SQLite replication

A container on Cloud Run, Fargate or Fly.io loses its disk at every
redeploy, and so would an SQLite database on it. `dartisan db:replicate`
streams the database to a storage disk (S3, R2, Google Cloud Storage, or
any [S3-compatible](s3.md) bucket) as it changes, the way Litestream does,
and `dartisan db:restore` rebuilds it, for example when a new container
starts. A restore loses at most what was committed since the last sync,
one second by default.

```bash
dart run bin/dartisan.dart db:replicate --disk=s3                 # until stopped
dart run bin/dartisan.dart db:restore --disk=s3 --if-missing      # at container start
dart run bin/dartisan.dart db:replicas --disk=s3                  # what is there
```

The database must be in WAL mode, which Daravel's SQLite driver sets. The
replica lives on the disk under `replicas/<database name>` (`--path`).

## How it works

The replicator takes a snapshot of the database, then reads the
write-ahead log as SQLite writes it and uploads each sync's committed
frames as a small compressed segment:

```text
replicas/app/generations/20261029T081500123Z-1f2e3d4c/snapshot-1793268900123.db.gz
replicas/app/generations/20261029T081500123Z-1f2e3d4c/wal/0000000000-1793268901004.wal.gz
replicas/app/generations/20261029T081500123Z-1f2e3d4c/wal/0000000001-1793268902011.wal.gz
```

A snapshot and the segments after it form a *generation*. A restore takes
the newest generation's snapshot and applies its segments in order.

Two rules keep a replica correct, whatever the application does meanwhile:

- **Only frames SQLite itself would trust are uploaded:** frames with the
  current log's salts, an unbroken checksum chain, and whole committed
  transactions. A transaction still being written waits for its commit.
- **When the replicator cannot prove it read every frame, it starts a
  generation** with a new snapshot. This happens when the log was
  restarted or truncated while it was not looking, for example while
  `db:replicate` was down. The snapshot is page-exact (SQLite's backup
  API), so the log's frames still apply to it.

Between syncs the replicator holds a read transaction, which keeps SQLite
from restarting the log under it. When the log reaches
`--checkpoint-pages` frames (1000), the replicator folds it into the
database itself, at a moment it controls, and follows the new log without
a new snapshot. To do so it writes one row in a `_daravel_replication`
table, as Litestream does with its own table. Every `--snapshot-hours`
(24) a new generation bounds how much a restore replays, and `--retain`
(2) generations are kept.

## Restoring

```bash
dart run bin/dartisan.dart db:restore --disk=s3                         # the newest state
dart run bin/dartisan.dart db:restore --disk=s3 --at=2026-10-29T08:00Z  # as of a moment
dart run bin/dartisan.dart db:restore --disk=s3 --to=copy.sqlite        # somewhere else
```

The restore is written next to the target and checked with `PRAGMA
integrity_check` before it replaces anything, and it never replaces an
existing file without `--force`. Stop the application before `--force`.
`--if-missing` does nothing when the database exists, which suits a
container's start command.

## Guarantees and limits

The test suite writes rows with consecutive ids from another isolate, with
checkpoints in between, and restores while it writes. Every restore must
be a prefix 1..k of the ids, and the last one must equal the database.
It also kills the replicator, as a process with SIGKILL and as an
isolate, and checks that a restore still has every row it had confirmed.

- One replicator per database. Running two does not damage anything, but
  they would checkpoint each other's log.
- The replica is as private as the disk: use a private bucket. Snapshots
  and segments are compressed, not encrypted; enable the bucket's
  server-side encryption.
- A restore replaces the whole file; it is not a read replica.
