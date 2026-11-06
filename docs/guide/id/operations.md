<!-- source: operations.md sha256:04e6bf11fedc -->
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
- Endpoint yang banyak melakukan alokasi per request (seribu baris lebar
  yang di-decode lalu di-encode menjadi JSON) kurang bisa scale di antara
  isolate dalam satu proses: dalam pengukuran, empat isolate hampir tidak
  menambah throughput sementara empat proses menambah 2,6×, kemungkinan
  besar karena isolate-isolate itu berbagi satu heap dan garbage
  collection-nya menghentikan semuanya. Pakai pagination untuk endpoint
  seperti itu, stream per halaman (`Response.streamJson`,
  [Response](responses.md#streaming-array-json-besar)), atau jalankan
  beberapa proses server di belakang proxy
  alih-alih menambah isolate: `APP_PROCESSES=N`
  ([Deployment](deployment.md#beberapa-proses)); skenario benchmark 13
  mengukurnya (`bench/README.md`). `dartisan doctor --production`
  menyarankan `APP_PROCESSES` (setengah jumlah core, dengan
  `APP_ISOLATES=2`) bila satu proses menjalankan empat isolate atau lebih,
  dan bila ada lebih dari satu worker mencatat
  `DART_VM_OPTIONS=--new_gen_semi_max_size=128`, new generation yang lebih
  besar yang sedikit mempersingkat request tersebut (81–90 ms menjadi
  70–77 ms).
- Setiap isolate punya memori sendiri, sehingga state yang disimpan aplikasi
  di static (daftar token yang dicabut, counter, nilai cache) ada satu per
  isolate. Simpan state itu di penyimpanan bersama sebelum menaikkan
  `APP_ISOLATES`: `RateLimiter` untuk batas dan counter,
  `Cache.store('process')` untuk nilai berumur pendek di satu mesin,
  penyimpanan cache `database` atau Redis untuk yang harus bertahan saat
  restart atau sampai ke setiap server (penyimpanan `process` menampung
  `CACHE_PROCESS_MAX_ENTRIES` entri, default 10.000, dan mulai kosong), dan `Auth.jwtGuard().invalidate()` untuk
  JWT. `dartisan lint` melaporkan static seperti itu
  (`no_mutable_static_in_app`).
- State per proses (rate limit, penyimpanan cache `process`, lock, metrik)
  melewati coordinator di isolate supervisor, sehingga batas seperti
  `throttle:60,1` berlaku untuk seluruh server, bukan per worker.
- Coordinator menjawab setiap worker dari satu event loop, jadi biaya
  mengirim sebuah nilai berpengaruh. VM membagi (share) sebuah string
  antar isolate dalam satu proses, tetapi menyalin map atau list, yang
  di-serialize oleh pengirimnya. Round trip terukur ke isolate lain dan
  kembali (Dart 3.13 AOT, `bench/bin/isolate_payload.dart`): dokumen
  888 KB sebagai `Map` memakan 9 ms, sebagai `String` JSON 6 µs, sebagai
  `Uint8List` 0,9 ms, dan sebagai `TransferableTypedData` 0,25 ms. Karena
  itu penyimpanan `process` mengirim nilai sebagai string JSON dan
  menyimpannya begitu saja di coordinator; angka dikirim sebagai angka,
  sehingga `increment` tetap bekerja. Kode aplikasi yang mengirim pesan
  sendiri antar isolate (coordinator service kustom, tugas compute)
  sebaiknya mengikuti pola yang sama: string untuk apa pun yang bisa
  diwakili JSON, `TransferableTypedData` untuk data biner besar, dan map
  hanya untuk argumen kecil.

## Koneksi database

Setiap isolate membuka pool sendiri berisi `DB_POOL_SIZE` koneksi (default
10, atau `pool=` di `DB_URL`), sehingga sebuah deployment membuka sampai:

```text
instances × APP_PROCESSES × (APP_ISOLATES + embedded worker) × DB_POOL_SIZE
```

koneksi (queue worker dan scheduler embedded, `SERVER_EMBED_QUEUE` /
`SERVER_EMBED_SCHEDULER`, adalah isolate dengan pool sendiri), ditambah
queue worker terpisah, scheduler, migrasi, dan aplikasi Laravel mana pun di
database yang sama. Jaga agar angka itu di bawah sekitar 80% dari
`max_connections` server (default 100 di PostgreSQL, 151 di MySQL dan
MariaDB). `dartisan doctor` menghitung hasil kali satu instance untuk
PostgreSQL, MySQL, dan MariaDB, membandingkannya dengan `max_connections`
server, dan memberi warning di atas 80%.

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
| `log_lines_dropped_total` | kenaikan apa pun: stdout, stderr, atau file log tertinggal atau gagal (pipe yang tidak dibaca, disk penuh), sehingga baris log dibuang alih-alih memblokir worker atau memenuhi memorinya |
| `shadow_replays_dropped_total`, `shadow_replays_failed_total` | dengan replay shadow `withUpstream`: laju replay yang dilewati yang terus-menerus (naikkan `UPSTREAM_SHADOW_MAX_CONCURRENCY` atau turunkan sample rate) atau replay yang tidak dijawab Laravel |
| `coordinator_messages_total` | lajunya (`rate(...[1m])`) yang ikut naik bersama trafik: setiap worker bertanya ke coordinator, yang menjawab di event loop supervisor |
| `coordinator_call_duration_seconds{service}` | p99 di atas sekitar 2 ms: rate limit, baca cache process, dan lock menunggu coordinator |
| `coordinator_rejected_total`, `coordinator_in_flight_peak` dibandingkan `coordinator_max_queue` | penolakan apa pun, atau puncak yang mendekati batas |
| `coordinator_call_timeouts_total{service}` | laju yang terus-menerus |
| `metrics_series_dropped_total{metric}` | nilai apa pun di atas nol: sebuah label dari metrik itu menerima nilai yang tidak terbatas |
| `coordinator_queue_lag_seconds`, `coordinator_queue_lag_peak_seconds` | di atas sekitar 25 ms: pesan menunggu selama itu di event loop coordinator (termasuk service sinkron seperti rate limit dan lock, yang tidak dihitung `coordinator_in_flight`), dan rate limit, yang menunggu 50 ms, mulai fail-open |
| `coordinator_expired_total` | laju yang terus-menerus: coordinator membuang percobaan rate limit dan pengambilan lock yang pemanggilnya sudah timeout, alih-alih menghitung atau memberikannya padahal tidak ada lagi yang menunggu |

Setiap metrik menyimpan paling banyak `METRICS_MAX_SERIES` set label per
worker (10 000 secara default, `0` berarti tanpa batas). Update untuk set
label baru di atas batas itu dihitung di series `{overflow="true"}` dari
metrik tersebut dan di `metrics_series_dropped_total`, sehingga label yang
diisi dari input user (sebuah path, sebuah id user) hanya memakan satu
series, bukan satu per nilai di setiap worker dan di coordinator. Label
`method` pada metrik HTTP bernilai `GET`, `HEAD`, `POST`, `PUT`, `PATCH`,
`DELETE`, `OPTIONS` atau `other`, karena client dapat mengirim token apa
pun sebagai method. Di bawah supervisor, setiap worker mengirim angkanya
saat angka itu berubah (dan setiap 15 detik apa pun yang terjadi), dan
series dari setiap worker dijumlahkan: beri gauge yang bukan total sebuah
label `worker`.

`dartisan coordinator:stats --url=http://127.0.0.1:8000/metrics` membaca
angka-angka ini dari server yang sedang berjalan dan memberi saran:
pakai cache store untuk rate limiter (`CACHE_LIMITER=database`), simpan
key cache process yang sering dibaca di setiap worker sebentar
(`CACHE_PROCESS_L1_TTL=1s`), atau pindahkan state itu ke Redis
(`withRedis()`).

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

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `php artisan down --secret / up` | `dartisan down --secret / up` | `PreventRequestsDuringMaintenance` | File storage/framework/down yang sama; cookie bypass `daravel_maintenance`. |
| `Log::info($message, $context)` | `Log.info(message, context)` | `Log.info` |  |
| `Log::withContext([...])` | `Log.withContext({...})` | `Log.withContext` |  |
