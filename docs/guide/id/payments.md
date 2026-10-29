<!-- source: payments.md sha256:a68530a8c96e -->
# Pembayaran

`daravel_payments` menerima pembayaran lewat Midtrans, Xendit, atau Stripe
di balik satu API, dan menerapkan notifikasinya tepat sekali: hanya dari
gateway, hanya untuk jumlah yang dipesan, tidak pernah dua kali, dan tidak
pernah mundur.

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

Tambahkan `CreatePaymentTables()` ke `bootstrap/migrations.dart` lalu
jalankan migrate. Migrasi ini membuat `payment_transactions` (satu baris
per pesanan dan gateway) dan `payment_webhook_logs` (satu baris per
notifikasi yang ditangani).

```dotenv
PAYMENT_GATEWAY=midtrans          # gateway default
MIDTRANS_SERVER_KEY=SB-Mid-server-...
MIDTRANS_IS_PRODUCTION=false
XENDIT_SECRET_KEY=xnd_development_...
XENDIT_WEBHOOK_TOKEN=...          # Dashboard → Webhooks → verification token
STRIPE_SECRET=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
```

Key tidak pernah muncul di response atau log: konfigurasi hanya
menampilkan apakah setiap gateway sudah dikonfigurasi.

## Menerima pembayaran

```dart
router.post('/checkout', (Request request) async {
  final order = await Order.find(request.input('order_id'));
  final checkout = await Payment.checkout(
    PaymentRequest(
      orderId: order.number,              // unik: gateway memakainya sebagai kunci
      amount: order.total,                // 150000 rupiah, 19.99 dolar
      items: [PaymentItem(name: order.title, price: order.total)],
      customer: PaymentCustomer(name: user.name, email: user.email),
      methods: ['qris', 'gopay'],         // nama dari gateway itu sendiri
      successUrl: 'https://shop.example/thanks',
    ),
    gateway: 'midtrans',                  // PAYMENT_GATEWAY bila tidak diisi
  );
  return checkout.toJson();               // redirect_url, token (Snap.js)
});
```

`amount` ditulis dalam satuan utama mata uangnya; setiap gateway
mengonversinya sesuai API-nya (unit terkecil untuk Stripe, rupiah bulat
untuk Midtrans). Pembayaran dicatat sebagai `pending`.

| Gateway | Yang dibuat | Pelanggan membayar di |
|---|---|---|
| Midtrans | transaksi Snap | `redirect_url`, atau Snap.js dengan `token` dan client key Anda |
| Xendit | invoice (`/v2/invoices`) | `redirect_url` (halaman invoice) |
| Stripe | Checkout Session | `redirect_url` (Stripe Checkout) |

Invoice Xendit adalah yang kini disebut Xendit sebagai payment link legacy,
di samping Payment Session; invoice tetap didukung penuh.

## Notifikasi

Atur URL notifikasi setiap gateway ke `https://<aplikasi Anda>/payments/webhook/<gateway>`:
`/payments/webhook/midtrans`, `/xendit`, atau `/stripe`. Setiap notifikasi:

1. **Diverifikasi.** Midtrans: `signature_key` harus sama dengan
   `SHA512(order_id + status_code + gross_amount + server key)`. Xendit:
   header `x-callback-token` harus sama dengan verification token Anda.
   Stripe: salah satu signature `v1` di `Stripe-Signature` harus sama
   dengan HMAC-SHA256 dari `<timestamp>.<body>` dengan endpoint secret,
   dan timestamp-nya paling jauh lima menit. Perbandingannya memakai waktu
   konstan. Selain itu dijawab 401 dan tidak mengubah apa pun.
2. **Diterapkan sekali.** Id-nya masuk ke `payment_webhook_logs` (unik per
   gateway) dalam transaksi yang sama dengan perubahannya. Pengiriman ulang
   dijawab `{"status": "duplicate"}` dan tidak melakukan apa pun.
3. **Diperiksa.** Baris pembayaran dikunci; notifikasi dengan jumlah lain
   tidak mengubah apa pun dan mengirim event `PaymentAmountMismatch`.
4. **Hanya bergerak maju.** `pending` → `paid`, `failed`, `expired`;
   `failed` atau `expired` → `paid` (pelunasan yang terlambat); `paid` →
   `refunded`. `pending` yang terlambat setelah `paid` diabaikan.

Event dikirim setelah commit, sehingga listener melihat pembayaran yang
sudah tersimpan:

```dart
events
  ..listen<PaymentPaid>((PaymentPaid paid) async {
    await Order.query().where('number', paid.payment.orderId).update({'status': 'paid'});
  })
  ..listen<PaymentAmountMismatch>((e) => Log.critical('Amount mismatch', {'order': e.payment.orderId}));
```

Pada semua kasus lain jawabannya 200 (`applied`, `unchanged`, `ignored`,
`unknownOrder`, `amountMismatch`), sehingga gateway berhenti mengirim ulang
notifikasi yang memang tidak perlu ditindaklanjuti lagi.

## Rekonsiliasi

Notifikasi bisa saja hilang. `dartisan payment:check ORDER-42` menanyakan
status pembayaran ke gateway lalu menerapkannya dengan cara yang sama.
Tambahkan `...paymentCommands` dari `package:daravel_payments/commands.dart`
ke `bootstrap/commands.dart`.

## Testing

```dart
final fake = Payment.fake();
(await client.post('/checkout', json: {'order_id': 42})).assertOk();
fake.assertCreated((request) => request.amount == 150000);

// Apa yang dilakukan aplikasi setelah lunas:
await Payment.manager.apply(fake.named('midtrans').event('ORDER-42', PaymentStatus.paid));
```

Tes paket ini sendiri memeriksa signature terhadap nilai yang dihitung
dengan `sha512sum` dan `openssl`, dan berjalan terhadap sandbox Midtrans
bila `MIDTRANS_SERVER_KEY` berisi key sandbox (`dart test --tags integration`).
