<!-- source: benchmarks.md sha256:b0ed4c28e1b8 -->
# Benchmark

Daravel hanya memublikasikan angka bersama skrip yang menghasilkannya,
mesin tempat skrip itu dijalankan, dan data pengukuran mentahnya
(BLUEPRINT_V2 P10). Halaman ini membandingkan Daravel dengan Laravel 12 yang
mengerjakan hal yang sama. Harness dan target internalnya ada di
[Performa](performance.md).

## Yang dibandingkan

Tiga server menjawab enam endpoint yang sama, di database yang sama dan di
core yang sama:

- **Daravel**: build AOT, dengan 1 dan 4 worker isolate.
- **Laravel Octane**: Laravel 12 di PHP 8.4 dengan OPcache, di worker mode
  FrankenPHP (aplikasi tetap di memori di antara request), dengan 1 dan 4
  worker.
- **Laravel klasik**: Laravel yang sama di FrankenPHP tanpa worker mode,
  yang mem-boot aplikasi di setiap request, seperti php-fpm.

| Skenario | Endpoint | Pekerjaan |
| :-- | :-- | :-- |
| overhead framework | `GET /ping` | respons teks, tanpa database |
| JSON + satu query | `GET /api/users/42` | `findOrFail`, model sebagai JSON |
| validasi + insert | `POST /api/users` | dua rule, satu insert di dalam transaksi |
| eager loading | `GET /api/posts` | 20 post beserta author dan masing-masing 10 komentar |
| route dengan rate limit | `GET /api/throttled` | `throttle` dengan batas yang tidak pernah tercapai |
| login | `POST /api/login` | mencari user, memverifikasi hash bcrypt (cost 10) |

Endpoint Laravel di `bench/laravel/overlay/` mengikuti
`bench/lib/bench_app.dart`: route, rule validasi, query, dan respons yang
sama. Konfigurasi, route, dan event Laravel di-cache, seperti di production.
Daravel mengisi database (1 000 user, 200 post, 2 000 komentar), dan Laravel
memverifikasi hash `$2y$`-nya apa adanya.

## Cara run publik dibuat

`bench/public.sh` menjalankan semuanya di satu mesin Linux dengan Docker,
lalu menulis hasilnya ke `bench/results/<tanggal>-<host>/`:

1. **Lingkungan**: model CPU, jumlah core dan thread per core, memori,
   virtualisasi, CPU governor, kernel, Docker, digest image Dart, PHP,
   FrankenPHP, Laravel, Octane, PostgreSQL, oha, commit, serta beban dan
   container yang berjalan di mesin sebelum run.
2. **Lima run** untuk setiap skenario, masing-masing 10 detik setelah
   pemanasan 2 detik, dengan 64 koneksi keep-alive. Tabelnya memuat median,
   dengan run terendah dan tertinggi di sampingnya, sehingga satu run yang
   bising terlihat sebagai rentang alih-alih menggeser angkanya.
3. **PostgreSQL**: skenario yang menjalankan query (2 sampai 4, serta
   overload dari skenario 11), juga lima run, terhadap server PostgreSQL 17
   yang baru.
4. **Overload**: Daravel saja (Laravel tidak punya padanannya) dibanjiri
   512 koneksi pada endpoint skenario 2, tanpa batas, dengan
   `HTTP_MAX_IN_FLIGHT`, dan dengan tambahan `HTTP_MAX_QUEUE_DELAY`
   ([load shedding](deployment.md#load-shedding)): goodput, p99 dari request
   yang berhasil, dan porsi yang ditolak dengan `503`, lima run.
5. **Kurva saturasi**: `/ping` dan skenario JSON pada 16, 64, 256, dan
   1 024 koneksi, dengan `dart:io` polos sebagai batas atas untuk `/ping`.
6. **Load generator kedua**: [oha](https://github.com/hatoo/oha), ditulis
   dalam Rust (versinya di-pin, checksum diverifikasi), mengukur Daravel
   dan Octane pada skenario GET. Jika angkanya sejalan dengan harness,
   hasilnya bukan berasal dari load generator Dart.
7. **Data mentah**: JSON setiap run disimpan di samping `report.md` dan
   `summary.json`.

Server (dan PostgreSQL) berjalan di separuh pertama core, dan load generator
di separuh kedua, sehingga keduanya tidak pernah berebut core.

### Perbedaan yang tersisa

- Rate limiter Laravel memakai cache `array`, sehingga setiap worker Octane
  menghitung sendiri-sendiri; batas di Daravel dibagi oleh semua isolate
  lewat coordinator, yang memerlukan satu pesan per request.
- `/ping` didaftarkan di luar grup middleware `web` Laravel (tanpa session
  dan CSRF), karena `/ping` di Daravel juga tidak memakainya.
- Di PostgreSQL, Daravel menyimpan pool 4 koneksi per isolate, sedangkan PHP
  memegang satu koneksi per worker Octane, dan versi klasik membuka koneksi
  di setiap request. Masing-masing adalah pengaturan normal runtime-nya.
- SQLite adalah file di disk yang sama untuk setiap server: driver Daravel
  dan Laravel sama-sama memakai WAL, `busy_timeout` 5000, dan
  `synchronous=NORMAL`.

Dua perbedaan pertama menguntungkan Laravel.

## Hasil

### Run yang dipublikasikan

Belum ada. Run di mesin khusus akan dicantumkan di sini beserta
lingkungannya, tabelnya, dan tautan ke data mentahnya di `bench/results/`.

### Run indikatif

Satu run pada 2026-10-26: WSL2 di laptop 16 thread, dengan container lain
ikut berjalan, 10 detik per skenario, 64 koneksi, empat worker, SQLite.
Karena hanya satu run di mesin yang dipakai bersama, bacalah rasionya,
bukan angka absolutnya.

| Skenario | Daravel | Laravel Octane | Laravel klasik |
| :-- | --: | --: | --: |
| `GET /ping` | 12 160 req/s | 2 254 req/s | 983 req/s |
| JSON + satu query | 9 594 req/s | 1 843 req/s | 720 req/s |
| validasi + insert | 2 918 req/s | 1 079 req/s | 551 req/s |
| eager loading (20 post) | 1 876 req/s | 440 req/s | 300 req/s |
| route dengan rate limit | 10 494 req/s | 1 721 req/s | 902 req/s |
| login (bcrypt, cost 10) | 35 req/s (61 sejak 1.10) | 72 req/s | 68 req/s |

Dengan satu worker, Daravel melayani 6 sampai 10 kali throughput Octane di
lima skenario pertama. Login adalah pengecualian: `package:bcrypt` di Dart
murni butuh 124 ms per hash, sedangkan bcrypt C di PHP butuh 70 ms. Sejak
1.10 Daravel menjalankan bcrypt C dari sistem di Linux (lihat
[Hashing](auth.md#hashing)); run kedua skenario login di mesin yang sama
memberi Daravel 61 req/s, Octane 55, dan klasik 47, sehingga biaya login
kini sama dengan di Laravel.

Untuk koneksi WebSocket (10 000 client Laravel Echo di satu server), lihat
[Broadcasting](broadcasting.md#kapasitas).

## Membaca angkanya

- **Throughput dan p99 bersama-sama.** Request per detik menunjukkan
  seberapa banyak yang bisa dikerjakan server; p99 menunjukkan berapa lama
  satu dari seratus user yang paling lambat menunggu. Dengan jumlah koneksi
  tetap, latensi sebagian besar adalah waktu di antrean, sehingga server
  yang lebih cepat juga punya p99 yang lebih rendah.
- **Kurva saturasi.** Saat koneksi bertambah, throughput mula-mula naik,
  lalu mendatar sementara p99 terus naik: dari titik itu, client tambahan
  hanya menunggu lebih lama. Error di kurva adalah respons 400 ke atas dan
  koneksi yang gagal.
- **Per core.** Setiap server mendapat core yang sama. Empat worker di empat
  core adalah perbandingan yang adil; satu worker menunjukkan biaya satu
  jalur request.
- **Perangkat Anda sendiri.** Skripnya butuh Linux, Docker, dan minimal
  empat core. Jalankan sendiri sebelum mengandalkan angka apa pun di sini.

## Menjalankannya sendiri

```bash
git clone https://github.com/daravel-dev/daravel && cd daravel
bash bench/public.sh                                  # sekitar satu jam di 8 core
RUNS=1 DURATION=3 CURVE=16,64 bash bench/public.sh    # dry run singkat
cat bench/results/*/report.md
```

`bench/laravel/compare.sh` menjalankan satu perbandingan (`DB=pgsql` untuk
PostgreSQL, `CONNECTIONS=16,64,256` untuk beberapa jumlah koneksi).
Pengaturan keduanya ada di
[bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md).
