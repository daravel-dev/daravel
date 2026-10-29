# Payments

`daravel_payments` takes payments through Midtrans, Xendit or Stripe behind
one API, and applies their notifications exactly once: only from the
gateway, only for the amount ordered, never twice, never backwards.

```bash
dartisan pub:add payments
```

```dart
// bootstrap/app.dart
import 'package:daravel_payments/daravel_payments.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withPayments()          // POST /payments/webhook/{gateway}
    // ...
    .create();
```

Add `CreatePaymentTables()` to `bootstrap/migrations.dart` and migrate. It
creates `payment_transactions` (one row per order and gateway) and
`payment_webhook_logs` (one row per notification handled).

```dotenv
PAYMENT_GATEWAY=midtrans          # the default gateway
MIDTRANS_SERVER_KEY=SB-Mid-server-...
MIDTRANS_IS_PRODUCTION=false
XENDIT_SECRET_KEY=xnd_development_...
XENDIT_WEBHOOK_TOKEN=...          # Dashboard → Webhooks → verification token
STRIPE_SECRET=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
```

The keys never reach a response or a log: the configuration exposes only
whether each gateway is configured.

## Taking a payment

```dart
router.post('/checkout', (Request request) async {
  final order = await Order.find(request.input('order_id'));
  final checkout = await Payment.checkout(
    PaymentRequest(
      orderId: order.number,              // unique: gateways key on it
      amount: order.total,                // 150000 rupiah, 19.99 dollars
      items: [PaymentItem(name: order.title, price: order.total)],
      customer: PaymentCustomer(name: user.name, email: user.email),
      methods: ['qris', 'gopay'],         // the gateway's own names
      successUrl: 'https://shop.example/thanks',
    ),
    gateway: 'midtrans',                  // PAYMENT_GATEWAY when left out
  );
  return checkout.toJson();               // redirect_url, token (Snap.js)
});
```

`amount` is in the currency's main unit; each gateway converts it as its
API expects (Stripe's minor units, Midtrans' whole rupiah). The payment is
recorded as `pending`.

| Gateway | Starts | The customer pays on |
|---|---|---|
| Midtrans | a Snap transaction | `redirect_url`, or Snap.js with `token` and your client key |
| Xendit | an invoice (`/v2/invoices`) | `redirect_url` (the invoice page) |
| Stripe | a Checkout Session | `redirect_url` (Stripe Checkout) |

Xendit's invoices are what it now calls its legacy payment links, next to
Payment Sessions; they remain fully supported.

## Notifications

Set each gateway's notification URL to `https://<your app>/payments/webhook/<gateway>`:
`/payments/webhook/midtrans`, `/xendit` or `/stripe`. Every notification is:

1. **Verified.** Midtrans: `signature_key` must be
   `SHA512(order_id + status_code + gross_amount + server key)`. Xendit:
   the `x-callback-token` header must be your verification token. Stripe:
   a `v1` signature in `Stripe-Signature` must be the HMAC-SHA256 of
   `<timestamp>.<body>` with the endpoint secret, and the timestamp must
   be within five minutes. Comparisons take constant time. Anything else
   gets 401 and changes nothing.
2. **Applied once.** Its id goes into `payment_webhook_logs` (unique per
   gateway), in the same transaction as the change. A retry answers
   `{"status": "duplicate"}` and does nothing.
3. **Checked.** The payment row is locked; a notification for another
   amount changes nothing and dispatches `PaymentAmountMismatch`.
4. **Moved forward only.** `pending` → `paid`, `failed`, `expired`;
   `failed` or `expired` → `paid` (a late settlement); `paid` →
   `refunded`. A late `pending` after `paid` is ignored.

Events are dispatched after the commit, so a listener sees the stored
payment:

```dart
events
  ..listen<PaymentPaid>((PaymentPaid paid) async {
    await Order.query().where('number', paid.payment.orderId).update({'status': 'paid'});
  })
  ..listen<PaymentAmountMismatch>((e) => Log.critical('Amount mismatch', {'order': e.payment.orderId}));
```

The answer is 200 in every other case (`applied`, `unchanged`, `ignored`,
`unknownOrder`, `amountMismatch`), so the gateway stops retrying a
notification there is nothing more to do with.

## Reconciling

A notification can get lost. `dartisan payment:check ORDER-42` asks the
gateway for the payment's status and applies it the same way. Add
`...paymentCommands` from `package:daravel_payments/commands.dart` to
`bootstrap/commands.dart`.

## Testing

```dart
final fake = Payment.fake();
(await client.post('/checkout', json: {'order_id': 42})).assertOk();
fake.assertCreated((request) => request.amount == 150000);

// What the application does once paid:
await Payment.manager.apply(fake.named('midtrans').event('ORDER-42', PaymentStatus.paid));
```

The package's own tests check the signatures against values computed with
`sha512sum` and `openssl`, and run against the Midtrans sandbox when
`MIDTRANS_SERVER_KEY` holds a sandbox key (`dart test --tags integration`).
