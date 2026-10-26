<!-- source: mail.md sha256:6f8172191c49 -->
# Mail dan notifikasi

`Mail` mengirim email lewat SMTP (atau transport lain) dan `Notifications`
mengirim notifikasi ke beberapa channel sekaligus: mail, database, atau
channel buatan Anda. Keduanya membaca pengaturan Laravel, dan notifikasi
yang disimpan memakai tabel `notifications` dari Laravel, sehingga aplikasi
Laravel di database yang sama juga bisa menampilkannya.

## Konfigurasi

Key-nya sama dengan `config/mail.php` di Laravel 12:

```dotenv
MAIL_MAILER=smtp              # smtp, log (default), array, atau transport Anda sendiri
MAIL_SCHEME=smtp              # smtp (STARTTLS bila ditawarkan) atau smtps (TLS, port 465)
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USERNAME=postmaster@example.com
MAIL_PASSWORD=secret
MAIL_FROM_ADDRESS=hello@example.com
MAIL_FROM_NAME="${APP_NAME}"
```

- `log` menulis setiap pesan, lengkap dengan MIME-nya, ke log alih-alih
  mengirimnya. Seperti di Laravel, ini default-nya, jadi tidak ada yang
  terkirim secara tidak sengaja.
- `array` menyimpan pesan di memori. Ini default saat `APP_ENV=testing`.
- `MAIL_ENCRYPTION` dari file `.env` Laravel 10 juga dibaca: `ssl` berarti
  smtps, dan `tls` mewajibkan STARTTLS. `MAIL_EHLO_DOMAIN` menetapkan nama
  EHLO (host dari `APP_URL` secara default) dan `MAIL_TIMEOUT` batas waktu
  setiap langkah SMTP (30s).

SMTP sudah tertanam (Dart murni): EHLO, STARTTLS, `AUTH PLAIN`/`LOGIN`,
satu koneksi per pesan. Untuk API HTTP milik penyedia layanan, daftarkan
sebuah transport:

```dart
.withMailTransport('postmark', (config) => PostmarkTransport(apiKey))
```

Transport mengimplementasikan
`MailTransport.send(MailMessage message, String mime)`. Pesannya berisi
penerima dan bagian-bagiannya, dan `mime` adalah teks RFC 5322 yang sudah
dirender.

## Mailable

<!-- dartisan make:mail OrderShipped -->
```dart
final class OrderShipped extends Mailable {
  OrderShipped(this.order);
  final Order order;

  @override
  Envelope envelope() => Envelope(
    subject: 'Order ${order.id} shipped',
    replyTo: [MailAddress('support@example.com', 'Support')],
  );

  @override
  MailContent content() => MailContent(
    html: '<p>Your order <b>${escapeHtml(order.number)}</b> is on its way.</p>',
    text: 'Your order ${order.number} is on its way.',
  );

  @override
  List<MailAttachment> attachments() => [
    MailAttachment.file('storage/app/invoices/${order.id}.pdf', as: 'invoice.pdf'),
  ];
}
```

`dartisan make:mail OrderShipped` menulisnya di `lib/app/mail/`. Escape
nilai yang Anda masukkan ke HTML dengan `escapeHtml`. Sertakan bagian teks
selain HTML bila bisa, karena aplikasi email dan filter spam lebih menyukai
pesan yang punya keduanya.

```dart
await Mail.to(user).send(OrderShipped(order));
await Mail.to('Ops <ops@example.com>').cc(['a@example.com']).bcc(auditor).send(report);
```

Penerima bisa berupa alamat, string `Name <address>`, model dengan atribut
`email` (dan `name`), atau list dari semua itu. Pengirimnya adalah `from` di
envelope, atau `MAIL_FROM_ADDRESS` / `MAIL_FROM_NAME`.

Pesannya berupa MIME standar: teks dan HTML sebagai
`multipart/alternative`, body quoted-printable, lampiran base64, dan encoding
RFC 2047 / 2231 untuk subjek, nama, dan nama file non-ASCII. Penerima Bcc
menerima pesan tanpa tercantum di dalamnya. Subjek, nama, alamat, dan header
yang mengandung pemisah baris ditolak dengan `ArgumentError`, karena tanpa
itu input user di sebuah header bisa dipakai untuk menambahkan penerima.

### Markdown mail dan tema

`MailContent(markdown: ...)` adalah mailable markdown ala Laravel: markdown
menjadi bagian HTML di dalam tema mail (header dengan `APP_NAME`, kartu
putih, footer), sekaligus menjadi bagian teks kecuali `text:` diberikan.
Komponen Laravel ditulis seperti di Blade, atau dengan `mailButton` dan
`mailPanel`, yang meng-escape apa yang diberikan:

```dart
@override
MailContent content() => MailContent(
  markdown: '''
# Order ${escapeHtml(order.number)} shipped

It is on its way.

${mailButton('Track your order', order.trackingUrl, color: 'success')}

<x-mail::panel>
Delivery **tomorrow** between 9 and 12.
</x-mail::panel>

Thanks,<br>
${escapeHtml(appName)}
''',
);
```

Temanya adalah tema default Laravel 12 (`default.css`), dengan style-nya
di-inline ke setiap elemen seperti yang dilakukan Laravel sebelum mengirim,
karena banyak aplikasi email mengabaikan `<style>`. Button menerima
`primary`, `success`, atau `error`. Ubah warna, logo, atau footer sekali
untuk semua mail:

```dart
Application.configure(basePath: '.')
    .withMailTheme((theme) => theme.copyWith(
      primary: '#4f46e5',
      logoUrl: 'https://example.com/logo.png',
    ))
```

Escape nilai yang Anda masukkan ke markdown dengan `escapeHtml`, seperti
`{{ }}` di Blade; sintaks markdown di dalamnya tetap berlaku, seperti di
Laravel.

## Notifikasi

<!-- dartisan make:notification InvoicePaid -->
```dart
final class InvoicePaid extends Notification {
  const InvoicePaid(this.invoice);
  final Invoice invoice;

  @override
  List<String> via(Object notifiable) => ['mail', 'database'];

  @override
  NotificationMail toMail(Object notifiable) => NotificationMail()
      .subject('Invoice paid')
      .line('We received your payment of ${invoice.total}.')
      .action('View invoice', 'https://example.com/invoices/${invoice.id}')
      .line('Thank you!');

  @override
  Map<String, Object?> toDatabase(Object notifiable) =>
      {'invoice_id': invoice.id, 'total': invoice.total};
}

await user.notify(InvoicePaid(invoice));                 // model apa pun
await Notifications.send(admins, InvoicePaid(invoice));  // sebuah list
await Notifications.route('mail', 'billing@example.com').notify(InvoicePaid(invoice));
```

`NotificationMail` adalah `MailMessage` notifikasi dari Laravel. Isinya
salam pembuka ("Hello!", atau "Whoops!" setelah `.error()`), baris-baris
teks, tombol opsional, dan salam penutup ("Regards," dan `APP_NAME`),
dirender di tema mail dari markdown yang sama dengan template
`notifications::email` Laravel, lengkap dengan subcopy "If you're having
trouble clicking..." di bawah tombol, dan sebagai teks. Subjek default-nya
nama kelas yang dipecah menjadi kata (`Invoice Paid`). `toMail` juga boleh mengembalikan `Mailable`.
Facade-nya bernama `Notifications` karena `Notification` adalah kelas
dasarnya.

| Channel | Mengirim | Penerima |
| :-- | :-- | :-- |
| `mail` | `toMail` | `email` dan `name` milik model, atau alamat dari `Notifications.route('mail', ...)` |
| `database` | `toDatabase` (atau `toArray`) ke `notifications` | sebuah model |
| `broadcast` | `toBroadcast` (atau `toArray`) sebagai event Laravel, melalui `BROADCAST_CONNECTION` ([Broadcasting](broadcasting.md)) | channel private milik model, atau `Notifications.route('broadcast', 'channel')` |
| buatan Anda | `withNotificationChannel('sms', SmsChannel())` | `routeNotificationFor('sms', ...)` |

Model menentukan rutenya sendiri dengan mengimplementasikan
`RoutesNotifications`:

```dart
final class User extends Model implements RoutesNotifications {
  // ...
  @override
  Object? routeNotificationFor(String channel, Notification n) =>
      channel == 'sms' ? this['phone'] : null; // null: pakai default
}
```

### Tabel notifications

Tambahkan `CreateNotificationsTable()` ke `bootstrap/migrations.dart`. Ini
tabel yang dibuat `make:notifications-table` di Laravel (`id` UUID, `type`,
`notifiable_type`/`notifiable_id`, `data`, `read_at`, timestamp), dan hanya
dibuat bila belum ada, jadi database yang sudah dimigrasi Laravel bisa
dipakai apa adanya. Baris ditulis seperti Laravel menulisnya:

- `type` adalah `App\Notifications\InvoicePaid` (timpa `databaseType`);
- `notifiable_type` adalah `morphClass` milik model (`App\Models\User`);
- `data` berupa JSON;
- setiap penerima mendapat UUID-nya sendiri.

```dart
final unread = await user.notifications(unreadOnly: true); // terbaru lebih dulu
await Notifications.markAsRead(user, [unread.first.id]);   // atau semua: markAsRead(user)
final count = await Notifications.unreadCount(user);
```

### Broadcast

Channel `broadcast` mengirim event `BroadcastNotificationCreated` dari
Laravel melalui `BROADCAST_CONNECTION` ([Broadcasting](broadcasting.md)):
di channel private milik notifiable, `private-App.Models.User.1`
(`morphClass` dengan titik, lalu key-nya), dengan

```json
{"invoice_id": 7, "total": 120000, "id": "<uuid>", "type": "App\Notifications\InvoicePaid"}
```

dari `toBroadcast`, atau `toArray` (seperti di Laravel, `toDatabase` tidak
dipakai), dan `id` yang sama dengan baris notifikasi di database. Laravel
Echo menerimanya seperti di Laravel:

```js
Echo.private(`App.Models.User.${userId}`).notification((notification) => {
  console.log(notification.type, notification.total);
});
```

`broadcastOn`, `broadcastAs`, dan `broadcastType` mengubah channel, nama
event, dan type-nya; `Notifications.route('broadcast', 'channel')` mengirim
ke sebuah channel tanpa model.

## Queue

Mengirim lewat SMTP butuh bolak-balik ke server lain. Masukkan pesan ke
queue agar request tidak perlu menunggunya:

```dart
await Mail.to(user).queue(OrderShipped(order));
await Mail.to(user).later(const Duration(minutes: 10), Reminder(order));

// Atau jadikan kelasnya sendiri masuk queue, seperti ShouldQueue di Laravel:
final class OrderShipped extends Mailable with ShouldQueue {
  @override
  String? get queue => 'mail'; // opsional; juga connection dan delay
  // ...
}
await Mail.to(user).send(OrderShipped(order)); // masuk queue; mengembalikan null
```

Notifikasi memakai mixin yang sama:
`final class InvoicePaid extends Notification with ShouldQueue`.

- Channel `mail` memasukkan mail yang sudah dirender ke queue.
- Channel `database` memasukkan baris yang akan di-insert ke queue. Id dan
  timestamp-nya adalah saat notifikasi dikirim.
- Channel buatan sendiri bisa mengimplementasikan
  `QueueableNotificationChannel`: `prepare` berjalan saat notifikasi dikirim
  dan mengembalikan JSON, dan `deliver` menerima JSON itu kembali di worker.
- Channel yang tidak mengimplementasikannya langsung mengirim.

Pekerjaan di queue berjalan di job milik framework sendiri (`daravel:mail`,
`daravel:notification`), jadi tidak ada yang perlu ditambahkan ke
`bootstrap/jobs.dart`. `dartisan queue:work` mengirimnya. Job mail dicoba 3
kali, dengan jeda 10 detik lalu 1 menit di antara percobaan.

Di dalam `DB.transaction`, job di-push saat transaksi di-commit dan dibuang
bila di-rollback (`QUEUE_AFTER_COMMIT`, aktif secara default), jadi pesanan
yang di-rollback tidak mengirim mail "pesanan dikonfirmasi".

Satu perbedaan dengan Laravel: pesan dirender saat dimasukkan ke queue,
bukan di worker. Laravel men-serialize mailable beserta model-modelnya dan
merendernya belakangan. Daravel tidak punya reflection untuk membangun ulang
objek sembarang, jadi job membawa pesan yang sudah jadi, termasuk
lampirannya. Mail menampilkan data seperti saat dimasukkan ke queue, yang
biasanya memang diinginkan, dan worker tidak butuh apa pun selain pengaturan
mail.

## Testing

```dart
final mail = Mail.fake();
await registerUser(...);
mail.assertSent<WelcomeMail>((m) => m.hasTo('teo@example.com'));
mail.assertNotSent<OrderShipped>();
mail.assertQueued<OrderShipped>((m) => m.hasTo('teo@example.com'));
mail.assertNothingSent();      // hanya yang terkirim; assertNothingOutgoing() mengecek keduanya

final notifications = Notifications.fake();
await order.ship();
notifications.assertSentTo<InvoicePaid>(user, (n, channels) => channels.contains('mail'));
notifications.assertSentOnDemand<InvoicePaid>();
notifications.assertSentTimes<InvoicePaid>(1);
```

`Mail.restore()` dan `Notifications.restore()` membatalkan fake-nya. Tanpa
fake pun test tidak mengirim apa-apa: `APP_ENV=testing` memakai transport
`array`, yang `messages`-nya menyimpan apa yang dikirim.
