import 'dart:async';

/// Set by the queue's processor in the zone of a running job: whether a
/// failure of it is retried (its driver keeps it, unlike `sync`, which
/// runs it inline in the caller and cannot). Internal: not exported.
final Object retryableJobKey = Object();

/// Whether the code runs in a job whose failure is retried: true for any
/// job a worker runs, not on `sync`. It is true on the last attempt too
/// (its `tries` used up), where raising sends the job to `failed_jobs`:
/// seen there, and retried by hand.
bool get inRetryableJob => Zone.current[retryableJobKey] == true;
