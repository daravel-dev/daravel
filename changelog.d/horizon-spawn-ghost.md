### Fixed

- `daravel_horizon`: a worker whose isolate failed to spawn no longer stays in its supervisor's pool. It was added before the spawn, so it counted as running for ever and no resize replaced it.
