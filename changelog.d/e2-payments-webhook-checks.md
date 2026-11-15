### Fixed

- `daravel_payments` compares a payment's amount and currency with the order, applies status changes transactionally, and records only events that move the payment as handled. Gateway keys must be nonempty; unreadable paid amounts or currencies receive 400. Unknown orders receive 409 by default, configurable with `unknownOrderStatus` on `withPayments` or `Payment.webhookRoutes`.
- Payment order and event identifiers are checked against the 255 Unicode character storage limit before database access. Webhooks receive 400 and application calls to `PaymentManager.apply` throw `ArgumentError` for longer identifiers. JSON log payloads larger than 65,535 UTF-8 bytes store a size marker while the event retains its raw data, without a schema migration.

### Changed

- Every verified Midtrans notification obtains its event from the status API for the authenticated order. A missing order lookup permits one transaction-id lookup, whose answer must still match that order. Status responses require a transaction id, status and code 2xx or 407 with `expire`; invalid or unavailable responses receive 5xx without applying an event. One lookup runs per order, with one shared subsequent batch for arrivals during it; completed responses are not cached.

### Upgrade notes

- Midtrans webhook handling requires outbound status API access for every verified notification, including `pending`, `settlement` and `capture`. Fake the status API in webhook tests, configure ingress rate limits, and handle 5xx responses during gateway outages. A missing order lookup is followed once by a transaction-id lookup; two missing answers receive 5xx. Direct `status(orderId)` calls continue to return `pending` for missing transactions.
- Midtrans event ids use `<order>:<transaction>:<status>[:<fraud_status>]` from the API response. Retries of events recorded with earlier identifiers can be evaluated again against the current payment state. `unknownOrderStatus: 200` acknowledges unknown orders when a gateway account is shared with another system.
