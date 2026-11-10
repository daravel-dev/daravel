### Added

- `SharedResult<T>`: the result of one computation awaited by several callers that may run in different zones (requests, jobs, connections). Its future never fails; `value` raises the computation's error again, with its own stack trace, in each caller's zone. A future that fails in one request's error zone never hands its error to a request waiting on it from another one, which then hangs: share results this way instead.

### Fixed

- Rate limits on a `process` store with several isolates: when the coordinator did not answer a lease in time, the other requests waiting on the same lease no longer hang until their request timeout. They fail open (or closed, with `failClosed`) at the coordinator's timeout, as the request that asked for the lease does.

### Upgrade notes

- New public name `SharedResult` in `package:daravel` (an application class of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
