<!-- source: performance.md sha256:3d0b47bdc9d5 -->
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
7. upload multipart 64 KB, di-parse dan dibaca,
8. respons SSE berisi sepuluh event, dibaca sampai selesai,
11. overload: skenario 2 di bawah koneksi yang jauh lebih banyak daripada
    yang bisa dilayani worker, tanpa batas, dengan `HTTP_MAX_IN_FLIGHT`, dan
    dengan tambahan `HTTP_MAX_QUEUE_DELAY` (lihat
    [Deployment](deployment.md#load-shedding)), dengan client yang langsung
    mencoba ulang (closed loop),
12. tiga server yang sama pada laju kedatangan tetap 1,5 kali kapasitasnya,
    dari client yang tidak mencoba ulang (open loop, kasus yang memang
    menjadi tujuan load shedding),

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

## Aplikasi Anda di bawah beban

`bench/` mengukur framework. `dartisan test:stress` mengukur aplikasi Anda,
di mana pun aplikasi itu berjalan (lokal, DDEV, staging): perintah ini
mencari skenario yang tersedia di aplikasi, melakukan warm-up, mengirim
beberapa round request lewat beberapa koneksi dan client isolate, lalu
melaporkan throughput antar-round (rata-rata ± standar deviasi) serta
latensi p50/p95/p99.

```bash
dartisan serve                                   # di terminal lain
dartisan test:stress --rounds=5 --requests=2000 --concurrency=50
dartisan test:stress --url=https://shop.ddev.site --path=/api/products
```

| Skenario | Request | Yang diharapkan |
|---|---|---|
| `health` | `GET /up` | 200 |
| `ping` | `GET /api/ping` | 200 |
| `not_found` | route yang tidak ada | 404 |
| `auth_me` | `GET /api/auth/me` dengan token user yang didaftarkannya (`stress_…@example.test`) | 200 |
| `rate_limit` | login gagal untuk satu email | 422, lalu 429 |
| `custom_N` | `GET` setiap `--path` | 200 |

Hanya skenario yang dijawab aplikasi yang dijalankan; `--scenario=ping,auth_me`
memilih sebagian. Setiap 5xx, request tanpa response, atau status yang
tidak diharapkan menggagalkan run (exit 1), begitu juga `--max-p95=150`
(milidetik) dan `--min-rps=500`, sehingga perintah ini bisa menjadi
performance gate di CI. Skenario login hanya dinilai dari status-nya,
karena hashing password memang sengaja membuatnya lambat.

`--json=report.json` menyimpan semuanya, termasuk target.
`--export-public=benchmarks.json` menulis apa yang boleh dipublikasikan:
statistik per skenario, status per kelas (`2xx`, `4xx`), pengaturan, serta
sistem operasi, jumlah CPU, dan versi Dart dan Daravel. File ini dibangun
dari daftar field yang diizinkan, sehingga URL, host dan port, token, user
sintetis, dan route `--path` tidak mungkin masuk. Sebelum mempublikasikan
sebuah angka, sebutkan apa yang menghasilkannya: mesinnya, apakah load
generator berbagi mesin yang sama, dan berapa round.

## Dibandingkan dengan Laravel

Perbandingan Daravel dengan Laravel 12 (Octane dan klasik) pada skenario
yang sama, beserta metode, hasil, dan cara mereproduksinya, ada di halaman
tersendiri: [Benchmark](benchmarks.md).
