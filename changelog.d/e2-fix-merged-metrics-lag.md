### Fixed

- Supervisor mode: a worker's metrics publish that the coordinator did not take (a timeout on a busy machine, a full bulk buffer, a refusal) is sent again on the next tick. Before, the worker counted it as published before the answer came, so an idle worker stayed out of the merged `/metrics` until its next heartbeat (15 ticks by default).
