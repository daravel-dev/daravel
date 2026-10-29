<!-- source: README.md sha256:edebc677ccce -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_pulse

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_pulse/README.md) · Bahasa Indonesia

Dashboard untuk [Daravel](https://pub.dev/packages/daravel) seperti Laravel
Pulse, disajikan oleh aplikasi Anda: request dan latensinya, request dan
query lambat, exception, queue dan job, digabung dari semua worker isolate,
tanpa database sendiri dan tanpa layanan eksternal.

```bash
dart pub add daravel_pulse
```

```dart
import 'package:daravel_pulse/daravel_pulse.dart';

Application createApp() => Application.configure(basePath: '.')
    .withPulse(middleware: ['auth', 'can:viewPulse'])
    // ...
    .create();
// https://your-app/pulse
```

- Request per menit (jumlah, server error, waktu rata-rata) selama 1, 6,
  atau 24 jam; request lambat per pola route, bukan path mentah.
- Query lambat per SQL, tanpa binding-nya; exception per class dan frame
  pertama di kode Anda, dengan trace terakhir.
- Ukuran queue, `failed_jobs` dalam periode itu, job lambat dan gagal.
- Setiap isolate mencatat dengan memori terbatas; di bawah supervisor,
  worker mengirim laporannya ke coordinator, sehingga halaman menampilkan
  seluruh proses.
- Key threshold Laravel Pulse (`PULSE_SLOW_QUERIES_THRESHOLD`, ...);
  halaman dengan Content-Security-Policy berbasis nonce tanpa aset
  eksternal; menjawab 403 di luar local sampai diberi middleware.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/pulse.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak
berafiliasi dengan dan tidak didukung oleh keduanya.
