<!-- source: performance.md sha256:5a88ccd9cdaf -->
# Performa

Daravel tidak membuat klaim performa tanpa angka yang bisa direproduksi
(BLUEPRINT_V2 P10). Harness di `bench/` mem-build server secara AOT lalu
mengukurnya:

```bash
cd bench
dart run bin/bench.dart --duration=10 --isolates=1,4 --out=results.json
```

Harness ini melaporkan request per detik dan latensi p50/p95/p99 untuk:

1. `GET /ping` (overhead framework),
2. JSON ditambah satu query,
3. validasi ditambah insert di dalam transaksi,
4. eager loading dua relasi,
5. route yang di-throttle (biaya coordinator),
6. login (bcrypt di compute pool),

ditambah microbenchmark Zone/facade, waktu startup, dan RSS saat idle untuk
setiap jumlah isolate. Setiap skenario juga dinyatakan relatif terhadap
server `dart:io` polos yang diukur di run yang sama; workflow nightly gagal
bila rasio itu turun lebih dari 10% dibanding `bench/baseline.json`.

Target internal (bukan janji publik): `/ping` dalam rentang 25% dari
`dart:io`, throttling menambah paling banyak 100 µs waktu layanan per
request, dan empat isolate memberi setidaknya tiga kali throughput satu
isolate di mesin dengan 4 core atau lebih. Lihat
[bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md)
untuk metodologinya.

## Dibandingkan dengan Laravel

`bench/laravel/compare.sh` menjalankan skenario yang sama terhadap Laravel
12.70 di PHP 8.4 dengan OPcache: sebagai Laravel Octane di worker mode
FrankenPHP, dan sebagai FrankenPHP klasik, yang mem-boot aplikasi di setiap
request seperti php-fpm. Endpoint-nya mengerjakan hal yang sama, di satu
database SQLite dengan pengaturan yang sama, dan setiap server berjalan di
empat core yang sama, terpisah dari load generator. Metodenya dan dua
perbedaan yang menguntungkan Laravel ada di
[bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md#against-laravel).

Satu run pada 2026-10-26 (WSL2 di laptop 16 thread, container lain ikut
berjalan, 10 detik per skenario, 64 koneksi), empat worker:

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
murni butuh 124 ms per hash, sedangkan bcrypt C di PHP butuh 70 ms. Kini
Daravel menjalankan bcrypt C milik sistem di Linux (lihat
[Hashing](auth.md#hashing)); run kedua skenario login di mesin yang sama
memberi Daravel 61 req/s, Octane 55, dan klasik 47, sehingga biaya login kini
sama dengan di Laravel. Jalankan skrip ini di perangkat Anda sendiri sebelum
mengandalkan angka-angka ini.
