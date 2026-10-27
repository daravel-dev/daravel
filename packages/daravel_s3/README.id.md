<!-- source: README.md sha256:6ce07026bcf7 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_s3

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_s3/README.md) · Bahasa Indonesia

Disk `Storage` [Daravel](https://pub.dev/packages/daravel) di atas AWS S3
dan penyimpanan yang kompatibel dengan S3: Cloudflare R2, MinIO,
DigitalOcean Spaces, Backblaze B2, Wasabi, dan Google Cloud Storage. Paket
ini membaca variabel `AWS_*` seperti Laravel, sehingga aplikasi Laravel dan
Daravel berbagi satu `.env` dan satu bucket.

```bash
dart pub add daravel_s3
```

```dart
Application.configure(basePath: '.').withS3() // AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_BUCKET, ...

await Storage.disk('s3').put('avatars/1.png', bytes);
await video.store('recordings', disk: 's3'); // multipart, satu part di memori

final url = Storage.disk('s3').temporaryUrl('invoices/1029.pdf', expiration: 30.minutes.fromNow);
final upload = Storage.disk('s3').temporaryUploadUrl('materials/a.mp4',
    expiration: 15.minutes.fromNow, contentType: 'video/mp4'); // url + headers untuk client
```

- AWS Signature Version 4 dalam Dart murni, diuji terhadap contoh S3 yang
  dipublikasikan AWS; tanpa AWS SDK, tetap satu binary AOT.
- Semua method `Disk`, diuji dengan tes kontrak yang sama seperti
  `LocalDisk` dan `MemoryDisk` di core; server-side copy, delete secara
  batch.
- Stream di-upload per part 8 MiB dan diunduh sambil datanya tiba.
- Presigned URL untuk unduhan dan upload langsung, serta form POST yang
  membatasi ukuran dan tipe upload; semuanya juga bekerja pada
  `Storage.fake()`.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/s3.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; Amazon S3 dan AWS adalah merek dagang Amazon.com,
Inc. atau afiliasinya; Cloudflare R2 adalah merek dagang Cloudflare, Inc.
Daravel adalah proyek independen, tidak berafiliasi dengan atau didukung
oleh pihak-pihak tersebut.
