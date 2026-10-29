<!-- source: pulse.md sha256:1f51dc620fea -->
# Pulse

`daravel_pulse` menyajikan sebuah dashboard, dari aplikasi Anda, tentang apa
yang sedang dikerjakannya: berapa banyak request yang dijawab dan seberapa
cepat, route mana yang lambat, query mana yang lambat, exception apa yang
dilempar, seberapa panjang queue, dan job mana yang gagal. Paket ini
mengikuti Laravel Pulse, tanpa database sendiri atau layanan eksternal:
setiap worker isolate mencatat di memori, dan halaman menggabungkannya.

```bash
dartisan pub:add pulse
```

`pub:add` menambahkan dependency, pemanggilan `.withPulse()` di bawah (tanpa
middleware: tambahkan sebelum halaman ini dipakai di luar local) dan
pengaturan `PULSE_*` ke `.env.example`. Dengan `dart pub add daravel_pulse`,
Anda mendaftarkannya sendiri:

```dart
// bootstrap/app.dart
import 'package:daravel_pulse/daravel_pulse.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withPulse(middleware: ['auth', 'can:viewPulse'])
    // ...
    .create();
```

Dashboard ada di `/pulse` (`PULSE_PATH`, atau `withPulse(path:
'/admin/pulse')`). Halaman ini diperbarui setiap lima detik dan menampilkan
1 jam, 6 jam, atau 24 jam terakhir.

## Siapa yang boleh melihat

Di luar `APP_ENV=local` dan `testing`, dashboard menjawab 403 sampai
`withPulse` diberi middleware, misalnya `auth` dan gate yang dipakai
Laravel Pulse:

```dart
// bootstrap/policies.dart
gate.define('viewPulse', (user, args) => user is User && user.isAdmin);
```

`PULSE_ENABLED=false` tidak mencatat apa pun dan menjawab 404.

## Yang ditampilkan

- **Request.** Jumlah, server error (5xx), request lambat, dan waktu
  rata-rata, dengan grafik sepanjang periode. Polling dashboard sendiri
  tidak dihitung.
- **Request lambat.** Dikelompokkan per pola route (`/users/{id}`, bukan
  path mentah), dengan jumlah dan yang paling lambat.
- **Query lambat.** Dikelompokkan per SQL dan koneksi. Binding tidak pernah
  disimpan, jadi nilai di dalam `where` tidak sampai ke halaman.
- **Exception.** Server error dikelompokkan per class dan per frame pertama
  di kode Anda, dengan pesan dan stack trace terakhir. Response 4xx
  (validasi, not found, forbidden) tidak dihitung sebagai exception di sini.
- **Queue dan job.** Job yang menunggu di setiap queue pada `PULSE_QUEUES`,
  baris `failed_jobs` dalam periode itu (dari semua proses worker, karena
  diambil dari tabel), dan job lambat atau gagal yang dijalankan isolate
  server ini.
- **Worker.** Setiap isolate, request yang sudah dijawabnya, request yang
  sedang berjalan, dan memori proses.

## Pengaturan

| Key | Default | Arti |
|---|---|---|
| `PULSE_ENABLED` | `true` | `false`: tidak ada yang dicatat, 404 |
| `PULSE_PATH` | `/pulse` | Path dashboard |
| `PULSE_SLOW_REQUESTS_THRESHOLD` | `1000` | Milidetik mulai sebuah request dicatat |
| `PULSE_SLOW_QUERIES_THRESHOLD` | `1000` | Milidetik mulai sebuah query dicatat |
| `PULSE_SLOW_JOBS_THRESHOLD` | `1000` | Milidetik mulai sebuah job dicatat |
| `PULSE_QUEUES` | `default` | Queue di koneksi default yang ukurannya ditampilkan |
| `PULSE_PUBLISH_SECONDS` | `5` | Seberapa sering worker mengirim laporannya, di bawah supervisor |

Key threshold sama dengan Laravel Pulse, jadi satu `.env` melayani keduanya.

## Cara kerjanya

Setiap isolate menyimpan sebuah `PulseRecorder`: jumlah request per menit,
serta request lambat, query lambat, exception, dan job dalam bucket sepuluh
menit, dikelompokkan (paling banyak 50 kelompok per jenis per bucket),
selama 24 jam. Pemakaian memori tetap terbatas, seberapa pun sibuknya
server.

Dengan `APP_ISOLATES` di atas 1, isolate yang mencatat sesuatu mengirim
laporannya ke coordinator beberapa detik kemudian (`PULSE_PUBLISH_SECONDS`),
dan isolate yang menjawab dashboard menggabungkan laporan terakhir setiap
worker dengan laporannya sendiri. Worker yang crash membawa laporannya
pergi. Data hidup di dalam proses: restart dimulai dari nol, dan dua server
di belakang load balancer masing-masing menampilkan datanya sendiri. Untuk
riwayat lintas restart dan lintas server, ekspor `/metrics` ke Prometheus
([Operasional](operations.md)).

Laravel Pulse menyimpan datanya di tabel `pulse_*`; data Daravel tidak
kompatibel dengan tabel itu, jadi aplikasi Laravel yang berbagi database
tetap memakai dashboard-nya sendiri.
