# Panduan Deployment (Deployment Guide)

Daravel menghadirkan keunggulan unik di ekosistem backend: **kompilasi AOT (Ahead-of-Time) menjadi satu executable biner mandiri (*single native binary*)**. Aplikasi Daravel tidak memerlukan instalasi Dart SDK, runtime Node.js, maupun PHP-FPM di server produksi.

---

## 1. Kompilasi Bundle Native

Gunakan perintah `dartisan build` untuk mengompilasi aplikasi ke kode mesin:

```bash
dart run bin/dartisan.dart build             # Menghasilkan folder build/server/bundle
dart run bin/dartisan.dart build --with-cli  # Menyertakan binary bin/dartisan di dalam bundle
```

Perintah `dartisan build` menjalankan `dart build cli` yang mengompilasi biner dan menjalankan *build hooks*: library native SQLite diunduh otomatis (diverifikasi hash SHA-256) dan diletakkan di `bundle/lib/`. Cukup salin folder `bundle/` ke server dan jalankan `bin/server`.

> [!TIP]
> **Optimasi Ukuran untuk PostgreSQL & MySQL**  
> Jika aplikasi Anda menggunakan PostgreSQL atau MySQL/MariaDB, hilangkan library SQLite untuk menghemat ukuran biner (~1.7 MB lebih kecil):
> ```bash
> dart run bin/dartisan.dart build --no-sqlite
> ```

---

## 2. Container & Docker

Perintah berikut membuat `Dockerfile` multi-stage (Dart SDK builder + `debian:bookworm-slim` runtime non-root user) yang siap pakai:

```bash
dart run bin/dartisan.dart build --docker
```

Image hasil build berukuran sangat ramping (~25 MB) dengan konsumsi memori idle sangat minim (~11 MB).

---

## 3. Deployment ke Google Cloud Run

Google Cloud Run adalah platform serverless berbasis container yang ideal untuk Daravel. Cloud Run secara otomatis menginjeksi variabel environment `PORT`. Daravel secara cerdas mengenali variabel `PORT` ini dan melakukan bind ke `0.0.0.0`.

### Langkah-langkah Deploy:

#### A. Siapkan Artefak & Image Registry
```bash
REGION=asia-southeast2
PROJECT=nama-project-gcp-anda
IMAGE=$REGION-docker.pkg.dev/$PROJECT/daravel/api:$(git rev-parse --short HEAD)
SQL=$PROJECT:$REGION:main-db

# 1. Buat repository Artifact Registry jika belum ada
gcloud artifacts repositories create daravel --repository-format=docker --location=$REGION

# 2. Build dan submit image container
gcloud builds submit --tag $IMAGE
```

#### B. Simpan Kredensial Sensitif di Secret Manager
Jangan menyimpan kunci rahasia di dalam image atau git repository:
```bash
printf '%s' 'base64:...' | gcloud secrets create app-key --data-file=-
printf '%s' 'rahasia-db'  | gcloud secrets create db-password --data-file=-
```

#### C. Deploy Service Cloud Run
```bash
gcloud run deploy api --image $IMAGE --region $REGION \
  --add-cloudsql-instances $SQL \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$SQL,DB_DATABASE=app,DB_USERNAME=app,APP_ISOLATES=2,DB_POOL_SIZE=5,SHUTDOWN_TIMEOUT=8s,QUEUE_CONNECTION=database" \
  --set-secrets "APP_KEY=app-key:latest,DB_PASSWORD=db-password:latest" \
  --cpu 2 --memory 512Mi --concurrency 200
```

#### D. Konfigurasi Probes (Health Checks)
Atur probe berikut di Cloud Run:
* **Startup Probe**: Arahkan ke `/up/ready` (memvalidasi kesiapan pool database).
* **Liveness Probe**: Arahkan ke `/up` (memverifikasi HTTP server aktif).

#### E. Menjalankan Migrasi Database
Jalankan migrasi database sebagai Cloud Run Job sebelum traffic dialihkan ke revisi baru:
```bash
gcloud run jobs deploy migrate --image $IMAGE --region $REGION \
  --set-cloudsql-instances $SQL \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$SQL,DB_DATABASE=app,DB_USERNAME=app" \
  --set-secrets "APP_KEY=app-key:latest,DB_PASSWORD=db-password:latest" \
  --command /app/bin/dartisan --args migrate
gcloud run jobs execute migrate --region $REGION --wait
```

---

## 4. Konkurensi & Multi-Isolate

Daravel memaksimalkan seluruh core CPU tanpa membutuhkan Redis untuk state lokal:
* Atur `APP_ISOLATES=N` sesuai jumlah vCPU (misal: `APP_ISOLATES=2` untuk server 2 core).
* Supervisor isolate akan mendistribusikan koneksi secara seimbang (*shared socket*).
* Status rate limit, proses cache L1, dan lock dikoordinasikan secara instan melalui isolate `Coordinator`.

---

## 5. Menjalankan Queue & Scheduler dalam Satu Proses

Untuk deployment hemat biaya (seperti 1 VPS atau 1 instance kecil), Daravel dapat menjalankan HTTP server, queue worker, dan cron scheduler dalam **satu proses**:

```bash
dart run bin/dartisan.dart serve --embed-queue --embed-scheduler
# Atau dari binary hasil compile:
SERVER_EMBED_QUEUE=true SERVER_EMBED_SCHEDULER=true bin/server
```
Queue worker dan scheduler masing-masing berjalan di isolate terpisah sehingga tidak akan pernah memblokir *event loop* request HTTP.
