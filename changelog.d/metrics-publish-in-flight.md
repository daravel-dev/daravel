### Fixed

- Supervisor mode: a worker sends no new metrics publish while the previous one waits for the coordinator's answer. Since a publish counts only once taken (so a failed one is sent again on the next tick), a coordinator slower than a tick received the same snapshot once per tick, more load exactly when it was slow (a test saw 11 sent while one waited). A publish that fails is still sent again on the next tick.
