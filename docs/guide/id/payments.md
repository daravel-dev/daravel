<!-- source: payments.md sha256:7c144201e727 -->
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
   konstan. Selain itu dijawab 401 dan tidak mengubah apa pun. Setiap
   notifikasi Midtrans yang terverifikasi memicu pencarian
   [API status](https://docs.midtrans.com/reference/get-transaction-status)
   berdasarkan `order_id` terautentikasi. Jawaban tidak ditemukan (kode
   404 tanpa status transaksi) memicu satu pencarian lagi berdasarkan
   `transaction_id` notifikasi, termasuk untuk DANA dan BI SNAP. Kedua
   jalur tetap mensyaratkan jawaban tentang order terautentikasi, id dan
   status transaksi berupa teks tak kosong, serta kode 2xx atau 407 dengan
   `expire`. Id event, status, jumlah, mata uang, waktu, dan payload mentah
   berasal dari API. Jawaban tidak sah, jawaban lunas tanpa `gross_amount`
   yang terbaca, atau dua jawaban tidak ditemukan menghasilkan 5xx tanpa
   menerapkan maupun mencatat event, sehingga Midtrans mengirim ulang
   notifikasinya. Pemanggilan langsung `status(orderId, reference:)`
   mencari order lewat `reference` bila Midtrans tidak mengenalnya lewat
   id-nya, dan menghasilkan `pending` bila keduanya tidak ditemukan; jawaban
   lunas tanpa jumlah yang terbaca juga melempar `PaymentGatewayException`
   di sana, sehingga rekonsiliasi tidak pernah melunaskan tanpa
   membandingkan jumlah. Notifikasi tanpa `transaction_id`, dengan
   `transaction_id` lebih dari 255 karakter, dengan `.` atau `..` sebagai
   id order atau transaksinya, atau dengan medan yang seharusnya teks
   tetapi bukan teks, dijawab 400 sebelum pencarian apa pun.
   Per order satu batch pencarian berjalan dan satu menunggu: notifikasi
   yang tiba selama sebuah batch masuk ke batch yang menunggu. Sebuah batch
   mencari order sekali dan, bila Midtrans tidak mengenalnya lewat id-nya,
   tiap `transaction_id` berbeda di batch itu bergiliran, sehingga tiap
   notifikasi menerima jawaban untuk transaksinya sendiri: paling banyak
   1 + 4 panggilan keluar per batch. `transaction_id` berbeda kelima saat
   batch yang menunggu penuh dijawab 429 dengan `Retry-After: 1`, yang
   diulang Midtrans. Tiap notifikasi untuk order lain membuat panggilannya
   sendiri; `HTTP_MAX_IN_FLIGHT` membatasi jumlah yang berjalan serentak.
   Jawaban yang selesai tidak disimpan sebagai cache.
   Atur pembatasan laju masuk melalui
   `Payment.webhookRoutes(middleware: ...)` dan perhitungkan panggilan
   status keluar serta ketersediaan gateway.
   Izinkan HTTPS keluar ke `api.midtrans.com` pada produksi atau
   `api.sandbox.midtrans.com` pada sandbox.
2. **Diterapkan sekali.** Id-nya masuk ke `payment_webhook_logs` (unik per
   gateway) dalam transaksi yang sama dengan perubahannya. Setelah sebuah
   notifikasi menggerakkan pembayaran, pengiriman ulangnya dijawab
   `{"status": "duplicate"}` dan tidak melakukan apa pun. Notifikasi yang
   tidak menggerakkan apa pun (`unknownOrder`, `unchanged`, `ignored`,
   `amountMismatch`) diperiksa lagi saat dikirim ulang, sehingga notifikasi
   yang tiba sebelum order-nya tersimpan diterapkan pada pengiriman ulang
   oleh gateway. Id Midtrans memuat order, transaksi, status, dan
   `fraud_status`: `capture` kartu yang ditahan untuk ditinjau
   (`challenge`) dan `capture` yang sama setelah diterima adalah dua
   notifikasi, dan notifikasi satu order tidak pernah dianggap milik order
   lain.
3. **Diperiksa.** Baris pembayaran dikunci; notifikasi dengan mata uang
   lain atau jumlah lain tidak mengubah apa pun dan mengirim event
   `PaymentAmountMismatch`. Tanpa mata uang, hanya jumlahnya yang
   dibandingkan.
4. **Hanya bergerak maju.** `pending` → `paid`, `failed`, `expired`;
   `failed` atau `expired` → `paid` (pelunasan yang terlambat); `paid` →
   `refunded`. `pending` yang terlambat setelah `paid` diabaikan.

Id order dan event dibatasi 255 karakter Unicode. Webhook yang melampaui
batas dijawab 400; `Payment.checkout` dan `Payment.manager.apply` dari
aplikasi melempar `ArgumentError` sebelum gateway atau basis data
dihubungi. Id event Midtrans memuat id order, id transaksi, dan status,
sehingga dengan Midtrans id order tetap jauh di bawah batas itu: Midtrans
sendiri mengizinkan 50 karakter untuk id order Snap
(`transaction_details.order_id`,
https://docs.midtrans.com/reference/json-objects). Pada MySQL, id event
yang hanya berbeda huruf besar-kecil dianggap satu event menurut kolasi
bawaan, sedangkan PostgreSQL dan SQLite membedakannya. Payload JSON log disimpan utuh
hingga 65.535 byte UTF-8; selebihnya hanya menyimpan
`{"truncated":true,"bytes":N}`. Event untuk listener aplikasi tetap membawa
payload mentahnya. Tidak diperlukan migrasi skema.

Event dikirim setelah commit, sehingga listener melihat pembayaran yang
sudah tersimpan:

```dart
events
  ..listen<PaymentPaid>((PaymentPaid paid) async {
    await Order.query().where('number', paid.payment.orderId).update({'status': 'paid'});
  })
  ..listen<PaymentAmountMismatch>((e) => Log.critical('Amount mismatch', {'order': e.payment.orderId}));
```

Notifikasi untuk order yang belum tersimpan (`unknownOrder`) dijawab 409:
Stripe, Midtrans, dan Xendit hanya mengirim ulang notifikasi sesudah
jawaban non-2xx, sehingga notifikasi itu diterapkan begitu order-nya ada.
Pada akun gateway yang dipakai bersama sistem lain, notifikasi untuk
order sistem itu lalu dikirim ulang sampai gateway menyerah dan tampil
gagal di dasbornya; gunakan `withPayments(unknownOrderStatus: 200)` untuk
menjawabnya 200 seperti sebelumnya. Pada semua kasus lain jawabannya 200
(`applied`, `duplicate`, `unchanged`, `ignored`, `amountMismatch`).
Notifikasi `amountMismatch` yang dikirim ulang diperiksa lagi dan mengirim
`PaymentAmountMismatch` lagi, jadi listener-nya sebaiknya idempoten.

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

Tes yang mengirim bentuk webhook Midtrans harus menyediakan fake
`api.sandbox.midtrans.com/v2/*/status` selain pembuatan checkout Snap.
Fake tersebut mengembalikan order yang diminta, id transaksi, status,
kode, dan jumlah. Gunakan `Payment.fake()` untuk menguji perilaku aplikasi saja.
