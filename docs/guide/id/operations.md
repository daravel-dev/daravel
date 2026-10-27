<!-- source: operations.md sha256:711fdc6d750b -->
# Operasional

Menjalankan Daravel di bawah trafik nyata: berapa isolate, berapa koneksi
database, kapan menolak pekerjaan, apa yang dipantau, dan bagaimana
menghentikannya. Mekanismenya ada di [Deployment](deployment.md); halaman ini
membahas angkanya. Ukur di perangkat Anda sendiri sebelum menetapkan salah
satunya ([Benchmark](benchmarks.md) menunjukkan caranya).

## Isolate

`APP_ISOLATES=N` menjalankan supervisor dan N worker isolate di satu port.
Setiap worker punya event loop sendiri, sehingga satu worker memakai paling
banyak satu core; satu isolate membiarkan core lainnya menganggur.

- Mulailah dengan satu isolate per core (atau vCPU) yang boleh dipakai
  server, lalu ukur. `dartisan doctor` mencatat
  `APP_ISOLATES=1: you are using 1 of N cores`.
- Di platform container, jumlah core adalah batas CPU container, bukan
  jumlah core host: dua vCPU berarti `APP_ISOLATES=2`.
- Isolate yang lebih banyak daripada core hanya menambah context switch,
  bukan throughput.
- State per proses (rate limit, penyimpanan cache `process`, lock, metrik)
  melewati coordinator di isolate supervisor, sehingga batas seperti
  `throttle:60,1` berlaku untuk seluruh server, bukan per worker.

## Koneksi database

Setiap isolate membuka pool sendiri berisi `DB_POOL_SIZE` koneksi (default
10, atau `pool=` di `DB_URL`), sehingga sebuah deployment membuka sampai:

```text
instances × APP_ISOLATES × DB_POOL_SIZE
```

koneksi, ditambah queue worker, scheduler, migrasi, dan aplikasi Laravel
mana pun di database yang sama. Jaga agar angka itu di bawah sekitar 80%
dari `max_connections` PostgreSQL (default 100). `dartisan doctor`
membandingkan satu instance dengan `max_connections` dan memberi warning di
atas 80%.

Jika hasil perkaliannya terlalu besar, turunkan `DB_POOL_SIZE` lebih dulu:
sebuah worker jarang butuh koneksi lebih banyak daripada jumlah request yang
sedang menunggu database pada saat yang sama. Jika Anda menjalankan banyak
instance, pasang connection pooler seperti PgBouncer di antara instance dan
PostgreSQL.

SQLite adalah file, bukan server: SQLite tidak punya batas koneksi, dan bukan
pilihan yang tepat untuk production dengan beberapa isolate (lihat
[Database](database.md#sqlite-atau-postgresql)).

## Load shedding

Tanpa batas, worker yang kelebihan beban mengantrekan setiap request sampai
semuanya timeout bersamaan. Dua batas per worker menolak kelebihannya dengan
`503` dan `Retry-After: 1` sebagai gantinya
([Load shedding](deployment.md#load-shedding)):

- `HTTP_MAX_QUEUE_DELAY` (proyek baru men-set `200ms`) menolak selama event
  loop worker terlambat sebanyak itu. Inilah batas yang bisa melihat
  pekerjaan yang berat di CPU atau SQLite, yang tidak terlihat oleh batas
  in-flight; set ke penundaan antrean yang bersedia Anda tambahkan ke sebuah
  respons, lalu ukur.
- `HTTP_MAX_IN_FLIGHT` membatasi request yang menunggu I/O sekaligus; sekitar
  2–4× `DB_POOL_SIZE` untuk worker yang mengakses database.

Penolakan yang terus-menerus (`http_requests_shed_total`) berarti server
butuh lebih banyak isolate atau instance, bukan batas yang lebih tinggi.

## Di belakang reverse proxy

Para worker berbagi port, dan sistem operasi menyerahkan setiap *koneksi*
baru ke salah satunya; request di koneksi itu tetap di worker tersebut.
Proxy yang menyimpan satu koneksi berumur panjang ke server akan mengirim
semuanya ke satu worker. Biarkan proxy menyimpan pool koneksi upstream,
beberapa per worker. Dengan nginx:

```nginx
upstream daravel {
    server 127.0.0.1:8000;
    keepalive 64;
}

server {
    location / {
        proxy_pass http://daravel;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
```

`http_requests_in_flight{worker="..."}` menunjukkan apakah beban para worker
merata.

## Yang dipantau

Aktifkan `/metrics` (`METRICS_ENABLED=true`, dengan `METRICS_TOKEN` di
production) dan scrape dengan Prometheus. Di bawah supervisor, angka dari
setiap worker digabungkan.

| Metrik | Perhatikan |
| :-- | :-- |
| `http_request_duration_seconds` | p99 per route (`histogram_quantile(0.99, ...)`): latensi yang dirasakan user |
| `http_requests_shed_total{worker}` | laju yang terus-menerus: server kelebihan beban |
| `http_requests_in_flight{worker}` | satu worker jauh lebih sibuk daripada yang lain: distribusi koneksi (lihat di atas) |
| `http_requests_total{status}` | porsi `5xx` |
| `process_resident_memory_bytes` | pertumbuhan terus-menerus selama berjam-jam atau berhari-hari |
| `coordinator_messages_total` | lajunya (`rate(...[1m])`) yang ikut naik bersama trafik: setiap worker bertanya ke coordinator, yang menjawab di event loop supervisor |

Koneksi database paling baik dipantau dari sisi database
(`pg_stat_activity` di PostgreSQL), dibandingkan dengan rumus di atas.

## Graceful shutdown

Saat menerima `SIGTERM` (atau `SIGINT`), server berhenti menerima koneksi,
`/up` menjawab `503` sehingga load balancer berhenti mengirim trafik,
WebSocket yang terbuka ditutup dengan "going away" agar client menyambung
ulang ke tempat lain, dan request yang sedang berjalan selesai dalam
`SHUTDOWN_TIMEOUT` (default 30 detik). Di bawah supervisor setiap worker
melakukan drain, dan worker yang masih berjalan dua detik setelah itu
dihentikan paksa.

Beri masa tenggang orchestrator lebih lama daripada `SHUTDOWN_TIMEOUT`:
Cloud Run menghentikan container 10 detik setelah `SIGTERM`, jadi pakai
`SHUTDOWN_TIMEOUT=8s` di sana; dengan systemd, jaga `TimeoutStopSec` tetap
di atasnya.
