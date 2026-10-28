<!-- source: README.md sha256:4bd4a8622ddf -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_log_viewer

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_log_viewer/README.md) · Bahasa Indonesia

Halaman log viewer untuk [Daravel](https://pub.dev/packages/daravel), yang
disajikan oleh aplikasi Anda: entri terbaru lebih dulu, filter level dan
teks, stack trace, dan entri baru secara live lewat server-sent events.
File dibaca dari ujungnya, sehingga 50 entri terakhir dari log 500 MB
kembali dalam waktu kurang dari satu milidetik.

```bash
dart pub add daravel_log_viewer
```

```dart
import 'package:daravel_log_viewer/daravel_log_viewer.dart';

Application createApp() => Application.configure(basePath: '.')
    .withLogViewer(middleware: ['auth', 'can:view-logs'])
    // ...
    .create();
// https://your-app/log-viewer
```

- Membaca log JSON harian Daravel dan file Monolog Laravel
  (`laravel.log`), termasuk stack trace multi-baris.
- Menelusuri mundur file sebesar apa pun dengan memori konstan; pencarian
  berhenti setelah membaca sejumlah tertentu isi file lalu menawarkan untuk
  lanjut.
- Menyembunyikan data rahasia (`password`, `token`, `authorization`, ...)
  di context dan teks; hanya membuka file `.log` di foldernya; halaman
  dengan Content-Security-Policy berbasis nonce tanpa aset eksternal;
  menjawab 403 di luar local sampai diberi middleware.
- Download dan hapus (opsional); API JSON untuk tool lain.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/log-viewer.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak
berafiliasi dengan dan tidak didukung oleh keduanya.
