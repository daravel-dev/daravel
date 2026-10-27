<!-- source: performance.md sha256:1d6af2d1d41d -->
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

Perbandingan Daravel dengan Laravel 12 (Octane dan klasik) pada skenario
yang sama, beserta metode, hasil, dan cara mereproduksinya, ada di halaman
tersendiri: [Benchmark](benchmarks.md).
