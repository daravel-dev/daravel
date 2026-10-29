# Changelog

## Unreleased

- First release: `withPulse(path:, middleware:)` records requests (count, server errors, latency by minute, slow requests by route), slow queries by SQL (never the bindings), exceptions by class and place with their trace, and slow or failed jobs, in each isolate, in bounded ten-minute buckets kept for a day. Under a supervisor every worker sends its report to the coordinator (`WorkerReportService`), so the dashboard at `/pulse` shows the whole process: 1, 6 or 24 hours, queue sizes, the `failed_jobs` of the period, the isolates and the memory. A nonce-based Content-Security-Policy, no external assets, and 403 outside local without middleware. The `PULSE_*` settings.
