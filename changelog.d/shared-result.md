### Fixed

- Rate limits on a `process` store with several isolates: when the coordinator did not answer a lease in time, the other requests waiting on the same lease no longer hang until their request timeout. They fail open (or closed, with `failClosed`) at the coordinator's timeout, as the request that asked for the lease does.
