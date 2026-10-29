<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_payments

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_payments/README.id.md)

Payments for [Daravel](https://pub.dev/packages/daravel) through Midtrans,
Xendit and Stripe, behind one API. A paid notification is applied once,
from the gateway only, for the amount ordered.

```bash
dart pub add daravel_payments
```

```dart
Application createApp() => Application.configure(basePath: '.')
    .withPayments()                                  // POST /payments/webhook/{gateway}
    .withMigrations(const [CreatePaymentTables()])
    // ...
    .create();

final checkout = await Payment.checkout(
  const PaymentRequest(orderId: 'ORDER-42', amount: 150000),
);
// checkout.redirectUrl: the gateway's payment page

events.listen<PaymentPaid>((paid) => fulfil(paid.payment.orderId));
```

- **Midtrans** Snap (QRIS, virtual accounts, e-wallets, cards); notifications
  checked with `SHA512(order_id + status_code + gross_amount + server key)`.
- **Xendit** invoices; callbacks checked with the `x-callback-token`.
- **Stripe** Checkout; webhooks checked with the `v1` HMAC-SHA256 of the
  timestamped body, five minutes of tolerance.
- **Exactly once:** an idempotency log keyed on the notification, the payment
  row locked, the amount compared with the order's, status moves that only
  go forward (a late `pending` never undoes `paid`), events after commit.
- `Payment.fake()` for tests, `dartisan payment:check <order>` for a missed
  webhook.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/payments.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Midtrans, Xendit and Stripe are trademarks of
their owners. Daravel is an independent project, not affiliated with or
endorsed by any of them.
