<!-- source: README.md sha256:9d57d4035a97 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_payments

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_payments/README.md) · Bahasa Indonesia

Pembayaran untuk [Daravel](https://pub.dev/packages/daravel) lewat Midtrans,
Xendit, dan Stripe, di balik satu API. Notifikasi lunas diterapkan sekali,
hanya bila datang dari gateway, dan hanya untuk jumlah yang dipesan.

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
// checkout.redirectUrl: halaman pembayaran gateway

events.listen<PaymentPaid>((paid) => fulfil(paid.payment.orderId));
```

- **Midtrans** Snap (QRIS, virtual account, e-wallet, kartu); notifikasi
  diperiksa dengan `SHA512(order_id + status_code + gross_amount + server key)`.
  Setiap notifikasi terverifikasi mengambil event dari API status untuk
  order terautentikasi, dengan satu pencarian id transaksi bila tidak ditemukan.
  Kegagalan API dijawab 5xx. Pencarian berjalan satu per order; notifikasi
  selama pencarian berbagi pencarian berikutnya tanpa cache hasil selesai.
  Sediakan fake API status pada tes webhook dan batasi laju masuk.
- **Xendit** invoice; callback diperiksa dengan `x-callback-token`.
- **Stripe** Checkout; webhook diperiksa dengan HMAC-SHA256 `v1` atas body
  bertimestamp, dengan toleransi lima menit.
- **Tepat sekali:** log idempotensi per notifikasi, baris pembayaran dikunci,
  mata uang dan jumlah dibandingkan dengan pesanan, status hanya bergerak
  maju (`pending` yang terlambat tidak membatalkan `paid`), event setelah
  commit. Notifikasi yang tidak menggerakkan apa pun diperiksa lagi saat
  gateway mengirimnya ulang.
- `Payment.fake()` untuk testing, `dartisan payment:check <order>` untuk
  webhook yang terlewat.
- Id order dan event dibatasi 255 karakter Unicode. Payload log di atas
  65.535 byte UTF-8 menyimpan penanda ukuran; data mentah event tetap tersedia.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/payments.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Midtrans, Xendit, dan Stripe adalah merek dagang
pemiliknya masing-masing. Daravel adalah proyek independen, tidak
berafiliasi dengan dan tidak didukung oleh pihak mana pun di antaranya.
