# Changelog

## 1.17.0

- First release: Midtrans (Snap), Xendit (invoices) and Stripe (Checkout) behind `Payment.checkout()`; webhooks verified as each gateway documents it (Midtrans' SHA-512 signature, Xendit's callback token, Stripe's `v1` HMAC with a five-minute tolerance) and applied exactly once (idempotency log, locked row, amount check, forward-only status moves, `PaymentPaid`/`PaymentFailed`/`PaymentExpired`/`PaymentRefunded`/`PaymentAmountMismatch` after commit); `Payment.fake()`; `payment:check`; `CreatePaymentTables`; the `PAYMENT_*`, `MIDTRANS_*`, `XENDIT_*` and `STRIPE_*` settings.
