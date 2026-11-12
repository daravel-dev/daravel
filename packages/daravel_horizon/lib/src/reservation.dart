/// When the queue may give a reserved job to another worker, as the
/// Horizon master judges it from a worker's report.
///
/// When the worker's driver counts with [retryAfter] too
/// ([reportedRetryAfterMs], the same configuration, as when master and
/// workers come from one `createApp`): what that driver said when it
/// reserved the job ([reservedUntilMs], `QueuedJob.reservedUntil`; the
/// database queue counts whole seconds, so 2 to 3 s after the reservation
/// for a `retry_after` of 3 s), exactly.
///
/// Otherwise the next pop may count with either value, so the earlier of
/// that and an estimate from [retryAfter] taken to count whole seconds (a
/// second less, from [reservedAtMs], when the worker saw the reservation),
/// which may come up to a second early; [mismatch] is then true when both
/// values were known and differ. Null when nothing was reported.
///
/// [reservedAtMs] is when the worker saw the reservation, after the pop
/// returned: later than the driver's own time by the pop's latency, so the
/// estimate may come that much late too. That path (a mismatch, or a
/// driver that does not report [reservedUntilMs]) relies on the margin
/// for it.
({DateTime? expiry, bool mismatch}) reservationExpiry({
  required Duration retryAfter,
  int? reservedAtMs,
  int? reservedUntilMs,
  int? reportedRetryAfterMs,
}) {
  final reported = reservedUntilMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(reservedUntilMs);
  if (reported != null && reportedRetryAfterMs == retryAfter.inMilliseconds) {
    return (expiry: reported, mismatch: false);
  }
  final estimate = reservedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(reservedAtMs)
            .add(retryAfter - const Duration(seconds: 1));
  if (reported == null || estimate == null) {
    return (expiry: reported ?? estimate, mismatch: false);
  }
  return (
    expiry: reported.isBefore(estimate) ? reported : estimate,
    mismatch: reportedRetryAfterMs != null,
  );
}
