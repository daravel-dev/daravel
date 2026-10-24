# Weekly Review #01 — Evaluasi Tier 0 & Tier 1 (Slice S1–S12)

> **Tanggal:** 2026-10-24
> **Cakupan yang Direview:** Tier 0 (Walking Skeleton) + Tier 1 (`S1` Foundation s/d `S12` CLI, Generators, Hot Reload, OpenAPI)
> **Slice Berikutnya:** `S13` (Testing Toolkit & Lints) · `S14` (Conformance Suite, Benchmarks, Docs)
> **Fokus Utama:** Keselarasan implementasi terhadap tujuan utama Daravel dibangun (Ergonomi Laravel + AOT Dart, Koeksistensi *Side-by-Side* Laravel ⇄ Daravel, Kesiapan `daragic`, dan Integrasi Ekosistem Flutter).

---

## 1. Evaluasi Apresiatif: Fondasi yang Sudah Sangat Tepat

Implementasi dari Tier 0 hingga `S12` di `packages/daravel`, `packages/dartisan_cli`, `packages/daravel_test`, dan `apps/daravel_starter` menunjukkan disiplin arsitektur yang sangat kuat terhadap [`BLUEPRINT_V2.md`](../../BLUEPRINT_V2.md):

1. **Resolusi Container Dua Tingkat (`Zone` + Root Fallback Per-Isolate):**
   Implementasi di `packages/daravel/lib/src/foundation/container.dart` dan `packages/daravel/lib/src/support/facades.dart` (`App`, `DB`, `Config`, `Log`, `Schema`, `Auth`, `Cache`, `Queue`, `Event`, `Storage`) memastikan semua facade bekerja konsisten baik di dalam siklus HTTP request, perintah CLI `dartisan`, queue worker, maupun test.
2. **Transaksi & Savepoint Berbasis `Zone` + `afterCommit`:**
   `DatabaseManager.transaction` dan `DatabaseManager.rollbackAfter` di `packages/daravel/lib/src/database/database_manager.dart` menangani transaksi bersarang otomatis lewat `SAVEPOINT`, antrean callback `afterCommit` (termasuk pembatalan job/event saat rollback), dan isolasi transaksi untuk test (`RefreshDatabase`).
3. **Trinitas Ergonomi Tanpa Magic (Generics + Explicit Registry + Scaffold-Time Generation):**
   Model Hybrid Active Record (`Model`, `ModelDefinition<T>`, `ModelQuery<T>`) yang dipadukan dengan marker region `// <dartisan:statics>` dan `// <dartisan:accessors>` serta `dartisan model:sync` berhasil menghadirkan ergonomi Eloquent tanpa `dart:mirrors` dan tanpa `build_runner`.
4. **Kompatibilitas Wire & Kriptografi dengan Laravel:**
   * `Encrypter` (`packages/daravel/lib/src/auth/encryption.dart`) mendukung `aes-256-gcm` sekaligus `aes-256-cbc` dengan format payload `base64(json({iv, value, mac, tag}))` yang *byte-compatible* dengan `Crypt::encryptString` di Laravel, lengkap dengan dukungan rotasi kunci `APP_PREVIOUS_KEYS`.
   * Hashing (`Argon2id`, `Bcrypt $2y$`, `PBKDF2`) berjalan di luar event loop utama dan mendukung verifikasi hash dari database Laravel.
   * Token personal access (`<id>|<secret>` dengan SHA-256 di `personal_access_tokens`) dan format JSON 422 / Paginator / `JsonResource` sudah mengikuti kontrak Laravel 11/12.
5. **Konkurensi Multi-Isolate (*Octane-Grade*) dengan Coordinator Isolate:**
   Pemisahan state `isolate` vs `process` melalui `Coordinator` dan `Supervisor` (`packages/daravel/lib/src/server/`) memastikan rate limiter (`throttle:`), cache lock, dan agregasi metrik Prometheus tetap akurat lintas worker isolate.

---

## 2. Review Kritis: Celah Strategis terhadap Tujuan Utama Daravel

Berdasarkan audit kode terhadap tujuan utama Daravel (**adopsi mudah oleh tim Laravel, koeksistensi *side-by-side* di database yang sama, dan kesiapan generator dua arah `daragic`**), ditemukan **6 celah utama** yang perlu segera ditangani:

### 2.1. Belum Aktifnya Driver Runtime MySQL / MariaDB (Blocker Koeksistensi #1)
* **Temuan:** Pada `packages/daravel/lib/src/database/database_manager.dart` (`_createDriver`), `SqlDialect.mysql` sudah memiliki query & schema grammar, tetapi pembukaan koneksi masih melempar `UnsupportedError('Database driver [mysql] is not available yet (MySQL/MariaDB arrives in slice S5b).')`.
* **Dampak:** Mayoritas (>80%) aplikasi produksi Laravel menggunakan MySQL/MariaDB. Sesuai **ADR-019** di `BLUEPRINT_V2.md` §14 No. 3, MySQL dinaikkan ke **Tier 1** karena koeksistensi Laravel + Daravel di satu database tidak dapat berjalan tanpa driver MySQL.

### 2.2. Ergonomi `FormRequest` & Route Model Binding di Controller Masih Manual
* **Temuan:**
  * Pada `apps/daravel_starter/lib/app/http/controllers/auth_controller.dart` dan `user_controller.dart`, validasi masih dipanggil secara manual di dalam body handler: `final data = await FormRequest.run(const StoreUserRequest(), request);`.
  * Pengambilan model di `UserController.show` masih manual dengan `request.param<int>('id')` dan `abort(404)`.
  * Dampaknya terlihat di `packages/dartisan_cli/lib/src/openapi.dart` (`buildOpenApi`): semua endpoint `POST/PUT/PATCH` hanya menghasilkan `'schema': {'type': 'object'}` kosong karena `RouteEntry` tidak mengetahui `FormRequest` atau `JsonResource` apa yang digunakan oleh rute tersebut.
* **Dampak:** Mengurangi ergonomi ala Laravel dan membuat dokumen OpenAPI serta ekstraksi IR `daragic` kehilangan informasi skema request/response.

### 2.3. Kurangnya Metadata Deklaratif pada `RouteEntry` & `ModelDefinition` untuk `daragic` (ADR-017)
* **Temuan:**
  * `RouteEntry` (`packages/daravel/lib/src/routing/route_entry.dart`) hanya menyimpan closure `final Handler handler;`. Pada runtime Dart (terutama AOT), tear-off metode seperti `users.store` bersifat *opaque* (tidak bisa diintrospeksi nama kelas controller dan nama metodenya tanpa informasi tambahan).
  * `ModelDefinition<T>` belum menyimpan metadata daftar relasi (`hasMany`, `belongsTo`, dll.) secara deklaratif.
* **Dampak:** `dartisan daragic:export` (konversi arah balik Daravel → Laravel) dan `dartisan route:list` tidak dapat menampilkan aksi controller (`UserController@store`) atau mengekspor DAM secara penuh dari introspeksi runtime saja.

### 2.4. Risiko Tabrakan Payload saat Berbagi Tabel `jobs` dan `cache` dengan Laravel
* **Temuan:**
  * Tabel `jobs` dan `cache` di Daravel memakai nama tabel dan kolom yang sama dengan Laravel agar kompatibel, namun format isi kolom `payload` / `value` berbeda (Laravel memakai envelope JSON `CallQueuedHandler` + PHP `serialize()`, sedangkan Daravel memakai JSON `JobRegistry`).
* **Dampak:** Dalam mode koeksistensi *side-by-side* di satu database, `dartisan queue:work` pada antrean `default` bisa mengambil job yang dikirim oleh Laravel (atau sebaliknya) dan menyebabkan job gagal karena perbedaan format payload.

### 2.5. Parser `model:sync` Masih Mengandalkan Regex pada Source File
* **Temuan:** `ModelSource.parse` di `packages/dartisan_cli/lib/src/model_sync.dart` mengekstrak nama tabel, primary key, dan map `casts` menggunakan `RegExp` atas teks file `.dart`.
* **Dampak:** Jika pengguna memformat `casts` dalam beberapa baris, memakai konstanta untuk nama tabel, atau menambahkan komentar di dalam blok `ModelDefinition`, regex berisiko gagal membaca metadata model.

### 2.6. Detail Konsistensi Kecil di CLI & Starter App
* Di `packages/dartisan_cli/lib/dartisan_cli.dart` (`AboutCommand`), versi masih tertulis `'0.0.1-dev (Tier 1 / S1)'` padahal implementasi sudah mencapai `S12`.
* Di `apps/daravel_starter/lib/app/http/controllers/auth_controller.dart` (`register`), pembuatan `User` dan pembuatan token belum dibungkus `DB.transaction(...)` seperti yang dicontohkan di `README.md`.

---

## 3. Masukan & Saran Perbaikan Teknis Konkret

### 3.1. Implementasikan `MysqlDriver` & `Schema.getColumns` MySQL (Prioritas Tinggi — S5b/S14)
* Sediakan implementasi `MysqlDriver` dan hubungkan ke `DatabaseManager._createDriver` untuk driver `'mysql'` dan `'mariadb'`.
* Pastikan `SchemaBuilder.getColumns` mendukung query `information_schema.columns` MySQL agar `dartisan model:sync` langsung dapat digunakan terhadap database aplikasi Laravel yang sudah ada.

### 3.2. Tambahkan Kontrak Deklaratif `.validates()` & `.returns()` pada `RouteEntry`
Perkaya `RouteEntry` di `packages/daravel/lib/src/routing/route_entry.dart` agar rute dapat mendeklarasikan kontrak input/output dan nama aksi:

```dart
router.post('/users', users.store)
    .action('UserController@store')
    .validates(StoreUserRequest.new)
    .returns<UserResource>();
```

**Keuntungan arsitektural:**
1. **Ergonomi Controller:** Pipeline rute menjalankan `FormRequest` secara otomatis sebelum memanggil handler; di dalam controller cukup memanggil `final data = request.validated();`.
2. **OpenAPI 3.1 Akurat Tanpa Refleksi:** `dartisan openapi:generate` dapat langsung membaca daftar `Rule` dari `StoreUserRequest` untuk menghasilkan properti `required`, `type`, `format`, `min`, `max`, dan `pattern` di `requestBody` OpenAPI!
3. **Kesiapan `daragic`:** `dartisan daragic:export` mendapatkan pemetaan `action`, `formRequest`, dan `resource` secara instan.

### 3.3. Lengkapi `daravel_test` di Slice S13 untuk Paritas Konversi Test Laravel
Agar test PHPUnit/Pest dari Laravel yang dikonversi oleh `daragic` dapat langsung berjalan tanpa ditulis ulang manual, lengkapi `packages/daravel_test/lib/daravel_test.dart` pada Slice `S13` dengan:
* `TestClient.actingAs(Authenticatable user, {String? guard})`
* `TestResponse.assertJsonValidationErrors(Object keysOrMessages)` & `assertJsonMissingValidationErrors([List<String>? keys])`
* `TestResponse.assertJsonStructure(Object structure)` & `assertJsonFragment(Map<String, Object?> fragment)`
* Helper assertion database: `assertDatabaseHas`, `assertDatabaseMissing`, `assertDatabaseCount`, `assertSoftDeleted`, `assertModelExists`.
* Helper siklus test: `withRefreshDatabase(Application app, Future<void> Function() testBody)` yang membungkus eksekusi dengan `DB.manager.rollbackAfter(...)`.

### 3.4. Isolasi Aman untuk Koeksistensi Queue & Cache
* Tambahkan dukungan prefix/isolasi antrean atau pengecekan header payload pada `DatabaseQueue` agar worker Daravel hanya meng-claim job yang memiliki format/namespace Daravel (atau menganjurkan konvensi antrean terpisah `queue: 'daravel'` pada mode koeksistensi).

### 3.5. Gunakan Introspeksi Runtime + Marker di `model:sync`
* Pada `ModelSyncCommand`, kombinasikan pembacaan metadata runtime dari `ModelDefinition` yang terdaftar di aplikasi (untuk `table`, `primaryKey`, `casts`) dengan penggantian teks berbasis marker `// <dartisan:accessors>`, sehingga tidak bergantung pada regex untuk membaca konfigurasi `ModelDefinition`.

---

## 4. Rekomendasi Inovasi Strategis ("Game-Changers" untuk Daravel)

Berikut adalah **5 inovasi strategis** yang disarankan untuk mempertegas diferensiasi Daravel sesuai tujuan utamanya:

### Inovasi 1: `dartisan adopt` — Mode *Strangler Fig* 5 Menit di Atas Proyek Laravel Existing
Sebelum tim Laravel melakukan migrasi penuh dengan `daragic`, berikan mereka cara tercepat untuk mencoba Daravel di samping proyek Laravel mereka:
* **Perintah:** `dartisan adopt --from-laravel=../laravel-app`
* **Cara kerja:**
  1. Membaca `.env` proyek Laravel (`APP_KEY`, `DB_*`, `REDIS_*`) dan menyelaraskan konfigurasi `.env` Daravel.
  2. Mengintrospeksi skema database Laravel yang sedang berjalan dan otomatis men-generate seluruh kelas `Model` Daravel beserta typed accessors dan casts-nya (`model:sync --all`).
  3. Menghasilkan template konfigurasi `nginx.conf` / `Caddyfile` untuk membagi trafik (*split routing* per prefix endpoint) antara binary Daravel dan PHP-FPM Laravel.
* **Dampak:** Tim Laravel dapat memindahkan 1 endpoint berbeban tinggi ke native binary Daravel dalam hitungan menit menggunakan token Sanctum dan tabel database yang sama.

### Inovasi 2: `dartisan client:flutter` — Generator SDK Flutter Bertipe Kuat Tanpa Build Runner
Menjawab kebutuhan Persona **"Tim Flutter + Laravel"** (`BLUEPRINT_DARAGIC.md` §2.3):
* **Perintah:** `dartisan client:flutter --out=../flutter_app/lib/daravel_client`
* **Cara kerja:** Dari rute yang sudah memiliki metadata `RouteEntry`, `FormRequest`, dan `JsonResource`, hasilkan paket/folder client Dart murni untuk Flutter yang berisi:
  * DTO request & response bertipe statis.
  * Method API per rute (`await api.auth.login(...)`, `await api.users.index(page: 1)`).
  * Penanganan error `422 Unprocessable Entity` otomatis yang memetakan `errors` per field langsung ke validator form Flutter.
* **Dampak:** Memberikan keunggulan setara Serverpod bagi developer Flutter, namun dengan arsitektur backend seanggun Laravel.

### Inovasi 3: Single-Binary All-in-One Production Mode (`--embed-queue` & `--embed-scheduler`)
Di PHP/Laravel, deployment produksi membutuhkan banyak komponen (`php-fpm`, `nginx`, `supervisord` untuk `queue:work`, dan `cron` untuk `schedule:run`).
* **Fitur:** Manfaatkan arsitektur Supervisor + Isolate Daravel untuk menyediakan flag `--embed-queue=<N>` dan `--embed-scheduler` pada binary server utama (`./build/server --isolates=4 --embed-queue=2 --embed-scheduler`).
* **Cara kerja:** Supervisor men-spawn isolate khusus untuk HTTP workers, Queue workers, dan Scheduler di dalam **satu proses binary AOT tunggal**, lengkap dengan *crash-loop respawn* dan *graceful drain* saat menerima `SIGINT`/`SIGTERM`.
* **Dampak:** Deployment aplikasi sekelas Laravel paling ringkas di industri — cukup satu file executable tanpa daemon tambahan.

### Inovasi 4: `parity.yaml` & Live Compatibility Score sejak Slice S14
* Mulai bangun file artefak mesin `parity.yaml` (ADR-016) pada Slice `S14` bersamaan dengan suite `test/conformance/`.
* Setiap fitur di `parity.yaml` ditautkan ke test konformansi yang memverifikasi kesamaan output byte/JSON terhadap fixture Laravel 12.
* Tampilkan metrik konformansi secara transparan di `README.md` (mis. badge *"Laravel 12 Wire Parity: Verified"*).

### Inovasi 5: Parser `PhpSerialize` Ringan (Primitives Only) di `package:daravel/php_compat.dart`
* Sediakan pembaca/penulis format PHP `serialize()` khusus tipe data primitif (`null`, `bool`, `int`, `double`, `String`, `List`, `Map` — tanpa instansiasi objek `O:` demi keamanan) di modul `php_compat`.
* **Dampak:** Memungkinkan `Crypt` dan `Cache` Daravel membaca langsung data cache dan nilai terenkripsi yang ditulis oleh `Crypt::encrypt()` / `Cache::put()` bawaan Laravel tanpa mengharuskan perubahan kode di sisi PHP.

---

## 5. Action Items (Target Tindak Lanjut untuk Review Minggu Depan)

Daftar ini akan dievaluasi statusnya pada review minggu ke-2:

- [ ] **[S13]** Lengkapi `packages/daravel_test` dengan `actingAs`, `assertJsonValidationErrors`, `assertJsonStructure`, database assertions (`assertDatabaseHas`, dll.), dan helper `RefreshDatabase`.
- [ ] **[S13]** Tambahkan architecture & lint tests (`no_dart_mirrors`, batas impor modul, verifikasi kelengkapan registry `bootstrap/*`).
- [ ] **[S5b / S14]** Implementasikan `MysqlDriver` (ADR-019) beserta `Schema.getColumns` untuk MySQL/MariaDB.
- [ ] **[S14]** Bangun suite `test/conformance/` untuk mengunci kontrak JSON 422, Paginator, `JsonResource`, Sanctum Token, `Hash`, dan `Crypt` terhadap fixture Laravel 12.
- [ ] **[DX / S12+]** Tambahkan metadata deklaratif (`.validates()`, `.returns()`, `.action()`) pada `RouteEntry` dan hubungkan ke `dartisan openapi:generate`.
- [ ] **[Housekeeping]** Perbarui string versi di `AboutCommand` (`packages/dartisan_cli/lib/dartisan_cli.dart`) dan bungkus `AuthController.register` di `apps/daravel_starter` dengan `DB.transaction`.
