<!-- source: deployment.md sha256:391ea9d0f728 -->
# Deployment

## Konsep & Arsitektur Ahead-of-Time (AOT) Single Binary

Daravel dirancang dari fondasinya untuk memutus ketergantungan pada runtime interpreter yang berat seperti PHP-FPM atau Node.js. Melalui kompilasi **Ahead-of-Time (AOT)**, seluruh kode aplikasi, router, middleware, ORM Eloquent, dan dependensi dikompilasi langsung menjadi **satu file biner mesin native (*native executable binary*)**:

```
 ┌────────────────────────────────────────────────────────────────────────────────────────┐
 │                        ALUR KOMPILASI AOT SINGLE BINARY DARAVEL                       │
 └────────────────────────────────────────────────────────────────────────────────────────┘
    Kode Sumber Proyek                  Tree-Shaking & AOT                   Hasil Akhir
  ┌─────────────────────┐              ┌────────────────────┐          ┌─────────────────────┐
  │ • routes/           │              │  dart build cli    │          │  bin/server         │
  │ • app/models/       │ ───────────▶ │  (dartisan build)  │ ───────▶ │  (Single Binary AOT │
  │ • app/controllers/  │              │  Kompilasi Mesin   │          │   ~25 MB, Standalone│
  │ • kernel & packages │              │  Bebas Reflection  │          │   Nol Dependensi OS)│
  └─────────────────────┘              └────────────────────┘          └─────────────────────┘
```

### Mengapa AOT Single Binary Menjadi Terobosan?

1. **Nol Dependensi Runtime di Server (*Zero Host Dependencies*):**
   Server produksi tidak perlu menginstal Dart SDK, tidak perlu interpreter runtime, dan tidak membawa folder dependensi raksasa seperti `vendor/` atau `node_modules/`. Biner hasil build dapat langsung dieksekusi di server Linux kosongan.
2. **Waktu Booting Secepat Kilat (*Cold-Start 25–40 ms*):**
   Tanpa overhead *bootstrapping* per-request seperti PHP atau startup V8 engine seperti Node.js, Daravel langsung menjalankan instruksi CPU mesin. Ini sangat ideal untuk arsitektur serverless autoscaling seperti **Google Cloud Run, AWS Fargate, atau Kubernetes KEDA** yang dapat melakukan *scale-to-zero*.
3. **Ukuran Image Container Super Ramping (~25–40 MB):**
   Daravel dapat dijalankan di dalam container *Distroless* atau *Debian Slim* minimalis, menghemat bandwidth deployment CI/CD dan penyimpanan registry cloud hingga 90% dibandingkan Docker image PHP-FPM (250–500 MB).
4. **Optimasi Tertutup (*Tree-Shaking & Closed-World*):**
   Compiler AOT secara otomatis membuang (*dead-code elimination*) seluruh fungsi dan class yang tidak pernah dipanggil dari `main()`, menghasilkan binary yang sangat teroptimasi dan aman dari serangan *gadget-chain*.

---

## Panduan Lengkap: Dari Build Sampai Deploy

Berikut adalah panduan langkah demi langkah mempersiapkan, mem-build, dan mendeploy aplikasi Daravel ke lingkungan produksi:

```
  ┌────────────────┐     ┌────────────────┐     ┌────────────────┐     ┌────────────────┐
  │ 1. PERSIAPAN   │ ──> │ 2. KOMPILASI   │ ──> │ 3. DEPLOYMENT  │ ──> │ 4. OPERASIONAL │
  │  • doctor      │     │  • native AOT  │     │  • Cloud Run   │     │  • health probe│
  │  • env:encrypt │     │  • Docker      │     │  • VPS/systemd │     │  • maintenance │
  └────────────────┘     └────────────────┘     └────────────────┘     └────────────────┘
```

---

## 1. Persiapan & Audit Pra-Build

Sebelum melakukan kompilasi biner, lakukan verifikasi integritas konfigurasi:

```bash
# 1. Jalankan audit kesiapan produksi
dart run bin/dartisan.dart doctor --production

# 2. Enkripsi file konfigurasi environment agar aman di-commit
dart run bin/dartisan.dart env:encrypt --env=production
```

`dartisan doctor --production` mewajibkan `APP_ENV=production` dan memeriksa keterjangkauan database, kunci aplikasi (`APP_KEY`), hashing password (`HASH_VERIFY`, `BCRYPT_ROUNDS`), proteksi route `/metrics`, dan memastikan driver queue bukan `sync`; lihat [Konfigurasi](configuration.md).

---

## 2. Kompilasi Biner (Native Bundle)

Daravel menyediakan perkakas build terintegrasi melalui CLI `dartisan build`:

```bash
dart run bin/dartisan.dart build             # → Menghasilkan build/server/bundle
dart run bin/dartisan.dart build --with-cli  # Menyertakan bin/dartisan di dalam bundle
```

`dartisan build` menjalankan `dart build cli`, yang mengompilasi AOT dan
menjalankan build hook: SQLite diunduh (hash-nya diverifikasi) dan diletakkan
di `bundle/lib/`. Salin seluruh direktori `bundle/` ke server lalu jalankan
`bin/server`. (`dart compile exe` tidak bisa dipakai karena menolak paket yang
punya build hook.)

Aplikasi di PostgreSQL atau MySQL tidak membutuhkan library SQLite di
bundle-nya:

```bash
dart run bin/dartisan.dart build --no-sqlite   # hanya bundle/bin/server (sekitar 1,7 MB lebih kecil)
```

`--no-sqlite` men-set opsi build `source: system` milik `package:sqlite3`
hanya selama build (di pubspec root workspace untuk anggota workspace) lalu
mengembalikan file itu sesudahnya, sehingga `dart run` dan `dart test` tetap
memakai SQLite bawaan yang biasanya diandalkan test. Opsi ini menolak bila
`DB_CONNECTION` bernilai `sqlite` (`--force` tetap mem-build, untuk server
yang punya `libsqlite3`); server yang kemudian membuka SQLite tanpa library
itu mendapat error yang menjelaskannya.

### Waktu build dan memori

`dartisan build` mengompilasi seluruh aplikasi secara ahead-of-time; di
laptop prosesnya satu sampai tiga menit. Di WSL2 dengan proyek pada bind
mount Windows (`/mnt/d/...`) terukur sebelas menit, sebagian besar untuk
akses file: simpan checkout di filesystem Linux (atau build di CI, atau di
filesystem container itu sendiri) dan waktunya kembali turun. Bundle-nya
sekitar 15 MB.

Ukur kebutuhan production dari biner, bukan dari server development:
`dartisan serve --watch` menahan analyzer dan JIT VM di memori (sekitar 1 GB
pada aplikasi berukuran sedang), sedangkan biner AOT diam di sekitar 15 MB
dan tetap di ratusan megabyte rendah di bawah beban dengan beberapa isolate
(115 MB dengan satu, sekitar 330 MB dengan delapan, pada aplikasi yang
sama).

## Docker

`dartisan build --docker` menulis `Dockerfile` multi-stage (builder Dart SDK,
runtime `debian:bookworm-slim`, user non-root, tanpa perlu SQLite sistem)
dan `.dockerignore`. Template `api` juga menyertakan `docker-compose.yml`
dengan PostgreSQL 16. Aplikasi referensi di repository ini menyertakan stage
runtime yang sama di `apps/daravel_starter/Dockerfile`, di-build dari root
repository (`docker build -f apps/daravel_starter/Dockerfile .`) karena ia
bagian dari pub workspace.

`dartisan build --docker --distroless` menulis stage build yang sama dengan
runtime [distroless](https://github.com/GoogleContainerTools/distroless)
(`gcr.io/distroless/cc-debian12:nonroot`): glibc dan sertifikat CA, tanpa
shell, tanpa package manager, dengan user `nonroot`. Image proyek baru
berukuran sekitar 84 MB. Karena tidak ada shell, command dijalankan dengan
`docker exec <container> /app/bin/dartisan migrate --force`.

## Port dan platform container

Server mendengarkan di `APP_HOST:APP_PORT` (`127.0.0.1:8000` secara default).
Di Cloud Run, Railway, Render, Fly.io, dan platform serupa yang menyuntikkan
variabel `PORT`, Daravel memakai port itu bila `APP_PORT` tidak di-set, lalu
bind ke `0.0.0.0` agar platform bisa menjangkaunya; `Dockerfile` yang
dihasilkan men-set `PORT=8080` sebagai default yang bisa ditimpa platform.
`SIGTERM` menuntaskan request yang sedang berjalan dalam `SHUTDOWN_TIMEOUT`.

## Konkurensi

`APP_ISOLATES=N` (atau `serve --isolates=N`) menjalankan supervisor dan N
worker isolate yang berbagi satu port. State per proses (rate limit,
penyimpanan cache `process`, lock, metrik) melewati coordinator. Mulailah
dengan satu isolate per vCPU lalu ukur (lihat [Performa](performance.md)).
SQLite `:memory:` tidak bisa dibagi antar-isolate. SQLite untuk
development, test, dan deployment dengan satu isolate; pakai PostgreSQL
untuk production dengan `APP_ISOLATES` lebih dari 1
([alasannya](database.md#sqlite-atau-postgresql)). Cara menentukan jumlah
isolate, koneksi, dan batas ada di [Operasional](operations.md).

### Beberapa proses

Isolate berbagi satu heap, sehingga endpoint yang banyak melakukan alokasi
per request (seribu baris lebar yang di-decode dan di-encode menjadi JSON)
hanya sedikit terbantu oleh isolate tambahan: dalam pengukuran, empat
isolate tetap di throughput satu isolate, sedangkan empat proses memberi
2,6×. `APP_PROCESSES=N` (atau `serve --processes=N`) menjalankan N proses
server di port berurutan, `APP_PORT` sampai `APP_PORT + N - 1`,
menjalankan ulang proses yang mati, dan menghentikan semuanya bersama saat
`SIGTERM`; perintah ini mencetak blok `upstream` nginx untuk dipasang di
depannya (Caddy: `reverse_proxy` dengan alamat yang sama). Setiap proses
punya penyimpanan cache `process`, rate limit, dan lock sendiri, sehingga
server menolak start sampai `CACHE_STORE`, `CACHE_LIMITER`, dan
`QUEUE_UNIQUE_LOCK_STORE` menunjuk ke `database` atau Redis
(`APP_PROCESSES_ALLOW_UNSHARED_STATE=true` menerima state per proses).
Gabungkan dengan `APP_ISOLATES` untuk endpoint yang terikat I/O: empat
proses berisi dua isolate di mesin delapan core. Platform container
melakukan hal yang sama dengan replika; pakai satu proses per replika di
sana.

## Load shedding

Tanpa batas, worker yang kelebihan beban menerima setiap koneksi yang
diberikan `dart:io` dan menjawabnya makin lama makin lambat, sampai semua
klien kena timeout sekaligus. Dua batas per worker menolak request seketika
sebagai gantinya, dengan `503 Service Unavailable`, `Retry-After: 1` dan
body JSON, sebelum routing, middleware, atau request scope berjalan.
Request tanpa body mempertahankan koneksi keep-alive-nya; yang body-nya
tidak terbaca ditutup. Health probe (`/up`, `/up/ready`) tidak pernah ditolak,
sehingga worker yang sibuk tidak di-restart karena sibuk. Keduanya mati
(`0`) secara default; proyek yang dibuat dengan `dartisan new` men-set
`HTTP_MAX_QUEUE_DELAY=200ms` di `.env.example`-nya.

- `HTTP_MAX_IN_FLIGHT=N` (`serve --max-in-flight=N`) membatasi request yang
  ditangani satu worker pada saat yang sama. Satu slot ditahan sampai
  respons tertulis dan `terminate()` (deferred work) selesai; WebSocket yang
  sudah di-upgrade menahan socket, bukan slot. Ini membatasi request yang
  *menunggu*: worker yang handler-nya menunggu PostgreSQL, Redis, atau
  layanan lain. Ia tidak melihat kerja sinkron: handler yang hanya menyentuh
  SQLite atau CPU selesai dalam satu putaran event loop, sehingga request
  kedua tidak pernah in-flight di sampingnya, seberapa pun panjang antrean
  di depan worker.
- `HTTP_MAX_QUEUE_DELAY=200ms` (`serve --max-queue-delay=200ms`) menolak
  request selama event loop worker berjalan lebih terlambat dari itu. Sebuah
  timer berdetak tiap 5 ms dan mengukur keterlambatannya sendiri, dihaluskan
  selama beberapa detak; keterlambatan itu adalah lamanya request menunggu
  di antrean socket dan event sebelum engine melihatnya, apa pun yang
  dilakukan handler. Inilah batas yang bisa melihat pekerjaan yang berat di
  CPU atau SQLite, yang tidak terlihat oleh batas in-flight; ukur efeknya di
  bawah beban Anda sendiri (skenario 12 di `bench/`). Di bawah supervisor,
  tiap worker mengukur loop-nya sendiri.

Worker berbagi port lewat `shared: true`, jadi kernel membagi *koneksi*,
bukan request, ke worker: satu worker bisa penuh saat yang lain masih lega,
dan server bisa menolak request sebelum seluruh
`APP_ISOLATES × HTTP_MAX_IN_FLIGHT` slot terpakai. Reverse proxy yang
membuka beberapa koneksi upstream meratakannya.

Tentukan nilainya dari load test (skenario 12 di `bench/` menjalankannya
dengan laju kedatangan tetap di atas kapasitas):
`HTTP_MAX_QUEUE_DELAY` adalah keterlambatan antrean yang rela Anda tambahkan
ke sebuah respons, dan `HTTP_MAX_IN_FLIGHT` sekitar 2–4× `DB_POOL_SIZE`
untuk worker yang mengakses database. Untuk aplikasi di PostgreSQL, batas
in-flight-lah yang membatasi latensi, karena worker yang menunggu database
tidak mengalami lag; `HTTP_MAX_QUEUE_DELAY` menangkap pekerjaan yang berat
di CPU. Penolakan dihitung di
`http_requests_shed_total{worker="..."}` pada `/metrics` (satu seri per
worker, seperti `http_requests_in_flight`) dan dicatat sebagai warning paling banyak sekali per detik,
menyebutkan batas yang tersentuh; penolakan yang terus-menerus berarti
server butuh lebih banyak isolate atau instance, bukan batas yang lebih
tinggi.

## Topologi

Jalankan Daravel di belakang reverse proxy (Caddy, nginx) yang mengakhiri TLS
dan mengompresi respons, lalu percayai proxy itu secara eksplisit:

```dart
TrustProxiesMiddleware(proxies: ['10.0.0.0/8'])
```

Tanpa itu, header `X-Forwarded-*` diabaikan.

## Secret: file environment terenkripsi

`dartisan env:encrypt` menulis `.env.encrypted` (atau
`.env.production.encrypted` dengan `--env=production`) dalam format
`php artisan env:encrypt`, sehingga kedua framework bisa membaca file yang
ditulis framework lainnya. File terenkripsi boleh di-commit; kuncinya tetap
di secret manager Anda:

```bash
dart run bin/dartisan.dart env:encrypt --env=production   # mencetak kunci baru
dart run bin/dartisan.dart env:encrypt --readable         # nama variabel tetap terlihat di diff
dart run bin/dartisan.dart env:decrypt --key=base64:...   # kembali ke .env
```

Saat runtime, set `DARAVEL_ENV_ENCRYPTION_KEY` (atau
`LARAVEL_ENV_ENCRYPTION_KEY`) dan aplikasi mendekripsi `.env.encrypted` dan
`.env.{APP_ENV}.encrypted` di memori saat boot; tidak ada `.env` biasa yang
ditulis ke disk. `.dockerignore` yang dihasilkan meloloskan file terenkripsi
ke dalam image. Kunci yang salah menghentikan boot dengan error yang jelas,
dan `dartisan doctor` memperingatkan bila sebuah file terenkripsi tidak
punya kunci.

`dartisan env:obfuscate --only=API_TOKEN` menulis kelas Dart yang nilainya
di-mask dengan XOR, sehingga tidak muncul di `strings bin/server` (berguna
untuk kunci yang dikompilasi ke dalam client). Ini obfuskasi, bukan enkripsi:
mask-nya ikut di biner yang sama, jadi tidak menggantikan `env:encrypt` untuk
secret sungguhan.

## Satu proses: queue dan scheduler tertanam

Deployment kecil (satu VPS, satu container) bisa menjalankan HTTP, sebuah
queue worker, dan scheduler dalam satu proses:

```bash
dart run bin/dartisan.dart serve --embed-queue --embed-scheduler
SERVER_EMBED_QUEUE=true SERVER_EMBED_SCHEDULER=true bin/server   # sama, dari bundle
```

Queue worker (di `SERVER_EMBED_QUEUES`, default-nya queue default) dan
scheduler masing-masing berjalan di isolate sendiri, sehingga job tidak
pernah memblokir event loop HTTP. Keduanya memakai coordinator server yang
sama, sehingga penyimpanan cache `process`, rate limit, dan lock-nya sama
dengan yang dilihat worker HTTP: token yang dicabut sebuah job ditolak pada
request berikutnya. Isolate yang crash dijalankan ulang; saat
`SIGTERM`, job atau tick yang sedang berjalan diselesaikan sebelum proses
keluar. Console command yang terjadwal berjalan bila server dijalankan dengan
`dartisan serve`; bila dijalankan sebagai `bin/server`, scheduler tertanam
menjalankan job, closure, dan task `exec`. Mode tertanam butuh database file
atau PostgreSQL (database SQLite in-memory ditolak). Untuk beberapa instance,
pertahankan satu scheduler tertanam (atau jalankan `schedule:work`
terpisah) dan skalakan queue worker secara terpisah.

## Google Cloud Run

`Dockerfile` yang dihasilkan berjalan di Cloud Run tanpa perubahan: ia
mendengarkan `PORT` yang disuntikkan, menulis log JSON ke stdout (diurai oleh
Cloud Logging), dan menyertakan `bin/dartisan` di samping `bin/server` untuk
command sekali jalan.

```bash
REGION=asia-southeast2
IMAGE=$REGION-docker.pkg.dev/$PROJECT/daravel/api:$(git rev-parse --short HEAD)
SQL=$PROJECT:$REGION:main          # instance Cloud SQL untuk PostgreSQL

gcloud artifacts repositories create daravel --repository-format=docker --location=$REGION
gcloud builds submit --tag $IMAGE

# Secret, sekali saja: APP_KEY dari `dartisan key:generate --show` dan password DB
printf '%s' 'base64:...' | gcloud secrets create app-key --data-file=-
printf '%s' '...'        | gcloud secrets create db-password --data-file=-

gcloud run deploy api --image $IMAGE --region $REGION \
  --add-cloudsql-instances $SQL \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$SQL,DB_DATABASE=app,DB_USERNAME=app,APP_ISOLATES=2,DB_POOL_SIZE=5,SHUTDOWN_TIMEOUT=8s,QUEUE_CONNECTION=database" \
  --set-secrets "APP_KEY=app-key:latest,DB_PASSWORD=db-password:latest" \
  --cpu 2 --memory 512Mi --concurrency 200
```

- **Cloud SQL.** `--add-cloudsql-instances` me-mount Unix socket instance di
  bawah `/cloudsql/`; `DB_HOST` yang di-set ke direktori itu terhubung
  melaluinya (seperti di Laravel). Pertahankan `DB_SSLMODE=disable` untuk
  socket; bila memakai IP privat, set `DB_HOST` ke IP tersebut dan
  `DB_SSLMODE=require`.
- **Koneksi.** Setiap isolate punya pool sendiri, sehingga database melihat
  hingga `instance × APP_ISOLATES × DB_POOL_SIZE` koneksi. Batasi
  `--max-instances` agar sesuai `max_connections` instance database.
- **Isolate.** Samakan `APP_ISOLATES` dengan `--cpu`.
- **Shutdown.** Cloud Run mengirim `SIGTERM` lalu mematikan container 10
  detik kemudian; `SHUTDOWN_TIMEOUT=8s` menuntaskan request yang sedang
  berjalan di dalam rentang itu.
- **Probe.** Arahkan startup probe ke `/up/ready` (mengecek database) dan
  liveness probe ke `/up`, di YAML service atau di console.

Migrasi dijalankan sebagai Cloud Run job dari image yang sama, sebelum
trafik pindah ke revisi baru:

```bash
gcloud run jobs deploy migrate --image $IMAGE --region $REGION \
  --set-cloudsql-instances $SQL \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$SQL,DB_DATABASE=app,DB_USERNAME=app" \
  --set-secrets "APP_KEY=app-key:latest,DB_PASSWORD=db-password:latest" \
  --command /app/bin/dartisan --args migrate
gcloud run jobs execute migrate --region $REGION --wait
```

Service Cloud Run hanya berjalan selama menangani request, jadi pekerjaan
latar belakang dipindahkan ke job yang dijalankan Cloud Scheduler, di-build
dengan cara yang sama: scheduler sebagai `--args schedule:run` setiap menit,
dan queue worker sebagai `--args queue:work,--stop-when-empty,--max-time=540`
setiap beberapa menit. Untuk queue yang terus sibuk, jalankan `queue:work`
di VM (bagian berikut).

## VPS dengan systemd dan Caddy

Build bundle di mesin dengan OS dan arsitektur CPU yang sama dengan server
(atau di CI), dengan `bin/dartisan` disertakan:

```bash
dart run bin/dartisan.dart build --with-cli
RELEASE=/srv/api/releases/$(date +%Y%m%d%H%M%S)
rsync -a build/server/bundle/ deploy@vps:$RELEASE/
ssh deploy@vps "cd $RELEASE && ln -s /srv/api/shared/.env .env \
  && ln -s /srv/api/shared/storage storage \
  && ./bin/dartisan migrate && ./bin/dartisan doctor --production \
  && ln -sfn $RELEASE /srv/api/current \
  && sudo systemctl restart api api-queue api-schedule"
```

Aplikasi membaca `.env` dari direktori kerjanya, jadi setiap rilis menautkan
`.env` dan `storage/` bersama. Rollback berarti mengarahkan `current` ke
rilis sebelumnya lalu me-restart.

`/etc/systemd/system/api.service`:

```ini
[Unit]
Description=Daravel API
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=daravel
WorkingDirectory=/srv/api/current
ExecStart=/srv/api/current/bin/server
Environment=APP_ISOLATES=4 SHUTDOWN_TIMEOUT=25s
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/srv/api/shared/storage
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Worker-nya adalah unit yang sama dengan command lain; keduanya berhenti
dengan rapi saat `SIGTERM` setelah job yang sedang berjalan selesai:

```ini
# /etc/systemd/system/api-queue.service ([Unit]/[Install] seperti di atas)
[Service]
User=daravel
WorkingDirectory=/srv/api/current
ExecStart=/srv/api/current/bin/dartisan queue:work --max-time=3600
Restart=always
TimeoutStopSec=90

# /etc/systemd/system/api-schedule.service
[Service]
User=daravel
WorkingDirectory=/srv/api/current
ExecStart=/srv/api/current/bin/dartisan schedule:work
Restart=always
```

`--max-time` me-restart queue worker setiap jam, dan `dartisan queue:restart`
meminta worker yang sedang berjalan keluar setelah job-nya selesai (misalnya
di akhir deploy). Set `TimeoutStopSec` di atas durasi job terlama.

Caddy mengakhiri TLS (sertifikat otomatis) dan mengompresi respons.
`/etc/caddy/Caddyfile`:

```caddyfile
api.example.com {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8000 {
		health_uri /up
	}
}
```

Pertahankan `APP_HOST=127.0.0.1` (default) agar server hanya bisa dijangkau
melalui Caddy, dan percayai Caddy dengan `TrustProxiesMiddleware(proxies:
['127.0.0.1/32'])`. Untuk memindahkan aplikasi Laravel endpoint demi endpoint
di belakang Caddy yang sama, lihat [Migrasi dari Laravel](migrating-from-laravel.md).

## Backup

`dartisan db:backup` menyalin database SQLite sementara server tetap
berjalan. Command ini memakai `VACUUM INTO` dari SQLite, yang menulis salinan yang
konsisten dan ringkas meskipun koneksi lain sedang menulis (menyalin file
dengan `cp` bisa menangkap tulisan yang baru setengah jadi), mengecek
salinannya dengan `PRAGMA integrity_check`, dan tidak pernah menimpa file:

```bash
dart run bin/dartisan.dart db:backup                  # storage/backups/database-<waktu>.sqlite
dart run bin/dartisan.dart db:backup --keep=14        # dan hapus semua kecuali 14 terbaru
dart run bin/dartisan.dart db:backup --output=/mnt/backups/app.sqlite
```

Jadwalkan di `routes/console.dart`, lalu salin `storage/backups` keluar dari
server (object storage, mesin lain):

```dart
schedule.command('db:backup', const ['--keep=14']).dailyAt('02:00');
```

Di PostgreSQL dan MySQL, command ini justru menjelaskan tool native-nya
(`pg_dump --format=custom`, `mysqldump --single-transaction`), yang mem-backup
server itu secara konsisten tanpa menghentikannya.

## Mode maintenance

```bash
dart run bin/dartisan.dart down --retry=60 --with-secret   # mencetak path untuk bypass
dart run bin/dartisan.dart up
```

`down` menulis `storage/framework/down` dalam format Laravel, dan server yang
sedang berjalan menjawab `503 {"message": "Service Unavailable"}` (dengan
`Retry-After` dan `Refresh` bila diberikan) dalam satu detik, tanpa restart.
Route health (`/up`, `/up/ready`) dan `--except=/path` tetap bisa diakses.
Mengunjungi `/<secret>` memasang cookie `daravel_maintenance` (ditandatangani
HMAC, berlaku 12 jam, seperti di Laravel) yang memungkinkan Anda memakai
aplikasi selama mode maintenance. Dengan beberapa server, file itu harus
berada di storage yang dipakai bersama, atau jalankan `down` di setiap server.

## Daftar periksa produksi

- `APP_ENV=production`, `APP_DEBUG=false` (boot gagal bila tidak, kecuali
  diizinkan secara eksplisit), dan `APP_KEY` 32 byte dari secret manager.
- `dart run bin/dartisan.dart doctor --production` mengecek konfigurasi,
  keterjangkauan database, `/metrics` yang terbuka untuk publik,
  `QUEUE_CONNECTION=sync`, dan lainnya; jalankan di entrypoint container.
- Endpoint health: `/up` (liveness) dan `/up/ready` (readiness).
- Jalankan `queue:work` dan `schedule:work` sebagai proses terpisah.
- Log: `LOG_STACK=json` untuk log terstruktur; secret di-redaksi.
