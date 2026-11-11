### Added

- Coordinator bulk credit (Blueprint #141, K1b): a worker's `RemoteCoordinatorChannel` keeps at most `bulkWindow` (16) bulk calls unanswered (`sendBulk`, or `callBulk` on any `CoordinatorChannel`), so the coordinator's port holds at most workers × 16 of them whatever the load, and critical calls (rate limits, locks) no longer wait behind a flood of broadcasts. Bulk calls beyond the window wait in order in a buffer of `bulkBuffer` (1 024) and go together as one `CoordinatorBatch` message once half the window is free; their answers come back together (`CoordinatorBatchReply`) when ready at once. A call gives its credit back with its answer or at its own timeout. A full buffer refuses a broadcast (`CoordinatorOverloaded`, dropped and told as `BroadcastShed`) and drops the oldest metrics, worker report or Horizon record (its future fails with `CoordinatorOverloaded`). A worker's last bulk calls are flushed (at most 2 s) when its application shuts down. `Coordinator.stats()` gains `port_messages` (a batch is one).

### Changed

- The coordinator learns its workers from one `CoordinatorHello` each channel sends when it opens, instead of from every request, and works out a call's priority only when it is not healthy (`served_by_priority` is sampled one call in 16 while healthy): the healthy path no longer pays for K1's bookkeeping on every message.

### Upgrade notes

- New public names `CoordinatorBatch`, `CoordinatorBatchReply`, `CoordinatorHello`, `BulkOverflow` and `BulkCoordinatorCalls` in `package:daravel` (an application class of one of these names and the barrel import give an ambiguous-import error; `hide` it or rename yours). Code that sends raw `CoordinatorRequest`s to a coordinator's port without a `RemoteCoordinatorChannel` is not told of its health unless it sends a `CoordinatorHello` first.
