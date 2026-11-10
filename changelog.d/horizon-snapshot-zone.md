### Fixed

- `daravel_horizon` dashboard: when the snapshot behind `stats`, `workload` and `stream` failed, the requests that had joined it while it ran (as the last one expired) never got an answer. Each request runs in its own error zone, and a future failing in one never hands its error to a request waiting on it from another. The shared snapshot now settles to its result or its error, raised again in each waiting request, so all of them answer.
