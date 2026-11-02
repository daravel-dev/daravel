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

- First release: Midtrans (Snap), Xendit (invoices) and Stripe (Checkout) behind `Payment.checkout()`; webhooks verified as each gateway documents it (Midtrans' SHA-512 signature, Xendit's callback token, Stripe's `v1` HMAC with a five-minute tolerance) and applied exactly once (idempotency log, locked row, amount check, forward-only status moves, `PaymentPaid`/`PaymentFailed`/`PaymentExpired`/`PaymentRefunded`/`PaymentAmountMismatch` after commit); `Payment.fake()`; `payment:check`; `CreatePaymentTables`; the `PAYMENT_*`, `MIDTRANS_*`, `XENDIT_*` and `STRIPE_*` settings.
