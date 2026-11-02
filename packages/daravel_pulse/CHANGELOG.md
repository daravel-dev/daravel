# Changelog

## 1.23.0

- Version aligned with Daravel 1.23.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.22.0

- Version aligned with Daravel 1.22.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.1

- Version aligned with Daravel 1.21.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.0

- Version aligned with Daravel 1.21.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.20.1

- Version aligned with Daravel 1.20.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- Version aligned with Daravel 1.19.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- Version aligned with Daravel 1.18.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.17.0

- Requires `daravel` 1.17.0, which brings the coordinator's `WorkerReportService`. 1.16.0 was published against `daravel` 1.16.0, which lacks it, and does not compile: use 1.17.0.

## 1.16.0

- First release: `withPulse(path:, middleware:)` records requests (count, server errors, latency by minute, slow requests by route), slow queries by SQL (never the bindings), exceptions by class and place with their trace, and slow or failed jobs, in each isolate, in bounded ten-minute buckets kept for a day. Under a supervisor every worker sends its report to the coordinator (`WorkerReportService`), so the dashboard at `/pulse` shows the whole process: 1, 6 or 24 hours, queue sizes, the `failed_jobs` of the period, the isolates and the memory. A nonce-based Content-Security-Policy, no external assets, and 403 outside local without middleware. The `PULSE_*` settings.
