# DARAVEL & DARTISAN — BLUEPRINT V2

## Review Kritis atas V1 + Pendalaman Konsep, Metode, dan Kerangka Menuju Implementasi Terbaik

> **Status:** Draft arsitektur, tahap pra-implementasi (acuan inovasi & best practice) · **Revisi V2.1** (2026-10-23): Bagian 14 dijawab dengan rekomendasi; Bagian 16 (`daragic`, generator dua arah Laravel ⇄ Daravel) ditambahkan; ADR-016…023 di 16.10 **menimpa** keputusan V2.0 yang disebutkan di sana
> **Tanggal:** 2026-10-23 · **Menggantikan:** `BLUEPRINT_V1.md`
> **Bahasa dokumen:** prosa Bahasa Indonesia; identifier, kode, dan istilah teknis tetap dalam bahasa Inggris agar konsisten dengan kode dan ekosistem Dart/Laravel.
> **Framework:** `Daravel` (Dart + filosofi Laravel 11/12) · **CLI:** `dartisan`
> **SDK minimum:** Dart `^3.9.0` (versi yang terpasang di mesin pengembangan saat ini); CI wajib menguji juga di *stable* terbaru (Dart 3.11 rilis Maret 2026; rilis berikutnya setiap ±3 bulan).
> **Runtime:** binary native AOT (`dart compile exe`) untuk produksi; JIT + hot reload VM Service untuk pengembangan.

---

## 0. Cara Membaca Dokumen Ini

Dokumen ini punya dua fungsi sekaligus:

1. **Review** — penilaian jujur atas V1: apa yang benar dan dipertahankan, apa yang salah, apa yang hilang, dan seberapa serius dampaknya bila dibawa ke implementasi tanpa diperbaiki (Bagian 1–2).
2. **Blueprint V2** — filosofi, keputusan arsitektur (ADR), spesifikasi modul yang diperdalam, kerangka keamanan, performa, kualitas, DX, dan peta jalan eksekusi (Bagian 3–16).

Legenda tingkat keparahan temuan review:

| Kode | Arti | Konsekuensi jika diabaikan |
| :-- | :-- | :-- |
| **K** (Kritis) | Salah secara teknis atau tidak akan berjalan | Kode tidak kompil, bug keamanan, atau rewrite besar di tengah jalan |
| **T** (Tinggi) | Desain tidak memadai untuk produksi | Perilaku salah pada beban nyata / multi-isolate / produksi |
| **S** (Sedang) | Kesenjangan fitur atau ergonomi yang memengaruhi adopsi | Developer Laravel merasa "setengah jadi" |
| **R** (Rendah) | Kosmetik, dokumentasi, konsistensi | Beban pemeliharaan |

Setiap keputusan penting dicatat sebagai **ADR** (Architecture Decision Record) dengan format: Konteks → Opsi → Keputusan → Konsekuensi. ADR adalah kontrak; mengubahnya harus lewat ADR baru, bukan diam-diam di kode.

---

## 1. Ringkasan Eksekutif

### 1.1 Putusan atas V1

V1 adalah **fondasi yang layak sebagai "spec-as-prompt"**: enam aturan non-negosiabelnya (AOT tanpa `dart:mirrors`, tanpa `build_runner` bagi pengguna, konteks per-request berbasis `Zone`, multi-isolate dengan `shared: true`, strict typing tanpa placeholder, dan SQL terparameter) adalah **pilihan yang tepat dan dipertahankan di V2**. Struktur monorepo *pub workspaces*, Radix tree router, dan arah ORM tanpa refleksi juga benar.

Namun V1 **belum siap dijadikan acuan implementasi** karena enam kelompok masalah:

1. **Cacat kontrak kode (K).** Sintaks generik di hampir semua kontrak salah (`<T Object extends>` seharusnya `<T extends Object>`; `Model<T Model<T extends>>` seharusnya `Model<T extends Model<T>>`). Kelas konkret `Application` mendeklarasikan metode tanpa badan. Jika AI executor menyalin kontrak ini mentah-mentah, fase 1 gagal kompilasi.
2. **Celah arsitektur yang memaksa rewrite (K/T).** `Container.current` hanya tersedia di dalam Zone request, sehingga semua facade mati saat boot, migrasi, CLI, dan test. Rate limiter dan cache in-memory bersifat per-isolate, sehingga `--isolates=4` secara diam-diam melipatgandakan batas rate 4×. Penulisan ulang placeholder `?` → `$1` secara tekstual bertabrakan dengan operator `?` JSONB PostgreSQL. SQLite `:memory:` adalah database terpisah di tiap isolate.
3. **Default keamanan yang berbahaya (K/T).** `clientIp` tanpa konsep *trusted proxies* membuat throttle bisa dilewati dengan header `X-Forwarded-For` palsu. Tidak ada batas ukuran body/multipart/kedalaman JSON. Hashing password murni-Dart dijalankan di isolate yang sama dengan HTTP sehingga memblokir event loop ratusan milidetik per login. Tidak ada `Crypt`, Gate/Policy, CSRF, maupun security headers.
4. **Kesenjangan fitur vs Laravel (S/T).** Tidak ada Queue/Jobs, Scheduler, Authorization (Gate/Policy), API Resources, Session, Model Factories, Cache locks, Storage cloud, Mail, Localization, WebSocket/SSE, dan OpenAPI. Query builder dan Schema builder baru mencakup ±40% permukaan API Laravel yang umum dipakai.
5. **Buta terhadap lanskap (T).** Nama paket `daravel_core` sudah terpakai di pub.dev (proyek lain, mangkrak sejak 2024) dan `dartisan` pun sudah diklaim (placeholder 2017). Framework Dart ber-rasa Laravel yang aktif sudah ada (`vania` 2.1.0 rilis 22 Okt 2026; `dartian` 1.0.0, AGPL). V1 tidak mendefinisikan diferensiasi.
6. **Proses eksekusi yang rapuh (S).** Fase monolitik "implementasikan semua modul lalu test" tanpa *walking skeleton*, tanpa suite konformansi perilaku Laravel, tanpa benchmark, tanpa definisi selesai yang terukur.

### 1.2 Dua Belas Perubahan Terbesar di V2

| # | Perubahan | Mengapa |
| :-- | :-- | :-- |
| 1 | **Trinitas ergonomi tanpa magic:** generics + *explicit registry* + *scaffold-time generation* (kode dihasilkan sekali oleh `dartisan make:*`, bukan oleh `build_runner` tiap build) | Dart macros resmi dihentikan Jan 2025; augmentations belum rilis. Ini satu-satunya jalur realistis menuju ergonomi Laravel yang 100% AOT |
| 2 | **Root container fallback per-isolate** + Zone untuk request scope | Facade harus hidup di boot, CLI, migrasi, test, dan job worker |
| 3 | **Model topologi "Octane-first"**: singleton = per-isolate, scoped = per-request, *shared* = lintas-isolate lewat *coordinator isolate* atau store eksternal | Rate limiter, cache lock, dan scheduler mutex harus benar pada N isolate |
| 4 | **Grammar emit placeholder saat kompilasi query**, bukan rewrite tekstual; `?` hanya di builder, raw SQL pakai *named bindings* `:name` | Aman terhadap operator `?` JSONB dan string literal |
| 5 | **ORM Hybrid Active Record**: *attribute bag* + typed accessor + `ModelDefinition<T>` + dirty tracking + relasi + model events | Paritas Eloquent yang sebenarnya (save/fill/casts/with/withCount/soft deletes) tanpa refleksi |
| 6 | **Keamanan secara default**: TrustProxies, body/multipart limits, Argon2id di worker isolate, Crypt AES-256-GCM, Gate/Policy, CSRF, security headers, signed URLs | Framework yang tidak aman secara default akan dipakai secara tidak aman |
| 7 | **Subsistem baru tier-1**: Queue & Jobs (sync/database/redis), Scheduler (cron), Authorization, API Resources, Factories, Cache locks | Tanpa ini, "Laravel di Dart" tidak kredibel untuk aplikasi nyata |
| 8 | **Hot reload sungguhan** via VM Service `reloadSources` (bukan hot-restart) dengan fallback restart | Umpan balik <1 detik mengalahkan `php artisan serve` |
| 9 | **Testing toolkit kelas satu**: `TestClient` fluent, `RefreshDatabase` berbasis transaksi, fakes (Event/Queue/Mail/Http/Clock) | Laravel dicintai karena testing-nya; Dart `test` + isolate paralel bisa lebih cepat |
| 10 | **Introspeksi runtime → OpenAPI** dari route registry + `Rule` objects + resource schemas | Nilai tambah unik: dokumentasi API gratis tanpa anotasi/refleksi |
| 11 | **Dependency policy "pure Dart first"** dengan daftar versi tervalidasi (Okt 2026) dan catatan native-lib (sqlite3) | Deploy AOT single-binary yang benar-benar portabel |
| 12 | **Eksekusi berbasis vertical slice** dengan walking skeleton, exit criteria terukur, suite konformansi, dan benchmark harness | Mengurangi risiko integrasi di akhir |

### 1.3 Temuan Riset yang Memengaruhi Keputusan (diverifikasi 23 Okt 2026)

- **Dart macros dihentikan** (pengumuman resmi tim Dart, Januari 2025); **augmentations** belum rilis per pertengahan 2026. Implikasi: jangan menunggu bahasa; desain harus berjalan tanpa metaprogramming.
- **Penamaan paket di pub.dev:** `daravel` → tersedia; `daravel_core` → **terpakai** (0.0.3, Nov 2024, berbasis shelf, SQLite saja, mangkrak); `dartisan` → **terpakai** (0.0.0, 2017, placeholder); `dartisan_cli` → tersedia; `daravel_framework` → tersedia. Lihat ADR-012.
- **Kompetitor:** `vania` 2.1.0 (aktif, rilis 22 Okt 2026; Laravel-flavored, ORM, migrasi, validasi, sesi, cache, mail, IoC; driver DB dipisah; opsional Redis/GraphQL/gRPC/OpenAPI/WebSocket), `dartian` 1.0.0 (Nov 2025, AGPL-3.0), `serverpod` 4.x (codegen berat, Postgres), `dart_frog` 1.2.x (file-based routing + build step), `angel3` 9.x, `conduit` 7.x, `shelf` 1.4.x (fondasi middleware de-facto).
- **Versi paket terbaru (pub.dev API):** `crypto` 3.0.7, `cryptography` 2.9.0, `bcrypt` 1.2.0, `sqlite3` 3.7.1, `postgres` 3.5.20, `redis` 4.1.0, `mime` 2.1.0, `path` 1.9.1, `meta` 1.19.0, `args` 2.7.0, `mason_logger` 0.3.6, `watcher` 1.2.1, `hotreloader` 4.4.0, `vm_service` 15.4.0, `clock` 1.1.3, `mailer` 7.2.0, `minio` 3.5.8, `uuid` 4.6.0, `yaml` 3.1.4, `http` 1.6.0, `test` 1.33.0, `lints` 6.1.0, `custom_lint` 0.8.1, `opentelemetry` 0.18.x, `mustache_template` 2.0.6. Catatan: `mysql_client` 0.0.27 terakhir rilis 2022 (risiko pemeliharaan; lihat ADR-013).

---

## 2. Review Kritis BLUEPRINT V1

### 2.1 Cacat pada Kontrak Kode (harus diperbaiki sebelum dibaca AI executor)

| Lokasi V1 | Masalah | Sev | Perbaikan V2 |
| :-- | :-- | :-- | :-- |
| `Container` (semua metode generik) | `void instance<T Object extends>(T value)` — urutan kata kunci terbalik; tidak kompil | K | `void instance<T extends Object>(T value)` dan seterusnya |
| `Model` / `ModelRepository` | `abstract class Model<T Model<T extends>>` — tidak kompil | K | `abstract class Model<T extends Model<T>>` |
| `Application.handleRequest`, `Application.serve` | Metode tanpa badan di kelas konkret | K | Beri implementasi, atau jadikan `abstract` + subclass; V2 memberi implementasi penuh |
| `Container.make` | `requestScope[T] as T` dengan nilai `null` untuk `T` non-nullable akan melempar `TypeError`, bukan `StateError` yang informatif | S | Pisahkan `containsKey` + null check, lempar `BindingResolutionException` |
| `Container.make` | Tidak ada deteksi dependensi sirkular; stack overflow sulit didiagnosis | S | Stack resolusi per-pemanggilan + `CircularDependencyException` |
| `Container` | Hanya satu binding per `Type`; tak ada *named/contextual binding* (mis. dua `Disk`) | S | Kunci `(Type, String? name)`; `make<Disk>(name: 's3')` |
| `typedef BindingFactory<T> = T Function(Container app)` | OK, tapi `Map<Type, BindingFactory<Object?>>` memaksa cast | R | Simpan `Object Function(Container)`; cast terjadi sekali di `make` |
| `Request.headers` sebagai `Map<String,String>` | Header multi-nilai (`Set-Cookie`, `Accept`) hilang | S | Kelas `Headers` case-insensitive multi-value |
| `Response.stream(... required String contentType)` | Parameter wajib diletakkan setelah opsional; gaya tidak konsisten | R | Named params konsisten |
| `Router.group({... required routes})` | Valid, tapi API Laravel lazim `group(attrs, closure)` | R | Pertahankan named params; tambah overload closure-first |
| `Rule.unique(...)` menerima `Container` di `validate` | Benar untuk AOT, tapi `data` bertipe `Map<String,dynamic>` sehingga nested rule (`items.*.id`) tak terdefinisi | S | Tambah `ValidationContext` (path, root data, container, locale) |
| `Hash` berbasis PBKDF2 saja | Tidak kompatibel dengan hash Laravel (`$2y$` bcrypt / `$argon2id$`) | S | Multi-driver + format PHC; lihat ADR-008 |
| `analysis_options.yaml` | Hanya 7 lint rules; tak mewarisi `package:lints/recommended` | R | `include: package:lints/recommended.yaml` + aturan tambahan + custom lint |

### 2.2 Celah Arsitektur

#### 2.2.1 Container hanya hidup di dalam Zone request — **K**

**Masalah.** `Container.current` membaca `Zone.current[zoneContainerKey]` dan melempar bila tidak ada. Zone hanya dibuat oleh `runInRequestScope`. Padahal facade (`DB`, `Config`, `Log`, `Cache`) juga dipakai saat `ServiceProvider.boot()`, migrasi, seeder, perintah CLI, job worker, scheduler, dan unit test.

**Dampak.** Separuh framework tidak bisa dipakai di luar HTTP; developer terpaksa membungkus semuanya dengan `runInRequestScope` palsu.

**Keputusan V2 (ADR-001).** Resolusi dua tingkat: (1) nilai Zone bila ada (request/job scope), (2) **root container per-isolate** (`static Container? _root`) yang di-set oleh `Application.boot()`. Statik per-isolate aman karena isolate tidak berbagi memori. Scope non-HTTP (job, perintah CLI, test case) memakai primitif yang sama: `container.runScoped(() async {...})` dengan nama scope (`request`, `job`, `command`, `test`).

#### 2.2.2 State in-memory per-isolate dianggap global — **K**

**Masalah.** `MemoryStore`, `RateLimiter`, `EventDispatcher`, dan `Cache` di V1 hidup per-isolate. Dengan `HttpServer.bind(shared: true)` koneksi didistribusikan antar isolate, jadi `throttle:60,1` sebenarnya menjadi `60 × N` dan `Cache.lock()` tidak bersifat eksklusif.

**Dampak.** Rate limiting bisa ditembus; idempotency, mutex scheduler, dan *once-only* job tidak dapat dijamin.

**Keputusan V2 (ADR-003).** Setiap store mendeklarasikan **cakupan**: `isolate` (cepat, tidak konsisten antar isolate), `process` (konsisten di satu proses lewat *coordinator isolate* + `SendPort`), `cluster` (Redis/DB). Rate limiter dan lock **default ke `process`** di mode multi-isolate dan **menolak** store `isolate` dengan error saat boot kecuali dikonfigurasi eksplisit. Dokumen harus jujur: `process` scope menambah ±1 round-trip pesan antar isolate (puluhan mikrodetik), masih jauh lebih murah dari Redis.

#### 2.2.3 Penulisan ulang placeholder `?` → `$1` secara tekstual — **T**

**Masalah.** PostgreSQL punya operator `?`, `?|`, `?&` (JSONB) dan `?` sah di dalam string literal/komentar. Regex rewrite akan merusak query sah.

**Keputusan V2 (ADR-005).** Grammar **mengemit** placeholder lewat `Grammar.parameter(index)` saat mengompilasi AST query, sehingga tidak pernah ada rewrite tekstual untuk query builder. Untuk `DB.raw`/`DB.select(sql)`, binding memakai **named parameters** `:name` dengan tokenizer yang sadar string literal, komentar, dan cast `::type`; `?` di raw SQL **tidak** diinterpretasi sebagai placeholder.

#### 2.2.4 SQLite `:memory:` dan multi-isolate — **T**

**Masalah.** Tiap isolate yang membuka `:memory:` mendapat database kosong terpisah. `dartisan serve --isolates=4` dengan SQLite memori menghasilkan empat "dunia" berbeda; `migrate` di isolate CLI tidak terlihat oleh server. Selain itu `package:sqlite3` adalah FFI **sinkron**: query panjang memblokir event loop isolate.

**Keputusan V2.** (a) Boot **menolak** `isolates > 1` bila koneksi SQLite memakai `:memory:` (error jelas, bukan perilaku diam). (b) SQLite file memakai `journal_mode=WAL`, `busy_timeout`, dan `synchronous=NORMAL` secara default; dokumentasi menyebut SQLite sebagai *dev/test/embedded tier*, PostgreSQL sebagai *production tier*. (c) `package:sqlite3` membutuhkan pustaka native (`libsqlite3.so`/`sqlite3.dll`): Dockerfile referensi memasang `libsqlite3-0`; `dartisan doctor` memeriksa keberadaannya.

#### 2.2.5 Transaksi: belum ada savepoint, belum ada afinitas koneksi — **T**

**Masalah.** `DB.transaction` bersarang di V1 tidak terdefinisi. Pada pool PostgreSQL, query di dalam transaksi harus memakai **koneksi yang sama**; V1 mengandalkan Zone key tetapi tidak menjelaskan bagaimana query builder, ORM, dan `Rule.unique` memakainya.

**Keputusan V2.** `DatabaseManager.executor` = `Zone.current[#daravel.tx] ?? pool`. Transaksi bersarang → `SAVEPOINT sp_n` (Postgres/SQLite keduanya mendukung). Opsi `attempts` untuk retry deadlock (`40P01`) seperti Laravel. Transaksi dibungkus `runZoned` dengan `zoneValues` baru sehingga pemanggilan bersarang otomatis ikut.

#### 2.2.6 Hot reload vs hot restart — **S**

V1 menjanjikan "sub-second hot-restart". Restart proses Dart JIT ±1–3 detik plus re-boot aplikasi dan koneksi DB. Dart VM mendukung **hot reload** sungguhan via VM Service (`reloadSources`), mekanisme yang dipakai `package:hotreloader` (4.4.0). V2 memakai hot reload dengan fallback restart bila reload ditolak (perubahan struktur kelas tertentu, inisialisasi top-level). Lihat ADR-010.

#### 2.2.7 Model tanpa dirty tracking, relasi, events — **T**

Model immutable V1 (`toMap`/`fromRow`/`fillable` di repository) bersih tetapi berhenti di CRUD. Tidak ada `save()`, `fill()`, `isDirty`, `casts`, `with()`, `belongsToMany`, `withCount`, soft deletes, global scopes, observers, `touch()`, `refresh()`. Developer Laravel akan menilai ini "bukan Eloquent". V2 mengganti dengan **Hybrid Active Record** (ADR-006) yang tetap tanpa refleksi.

#### 2.2.8 Tidak ada registri eksplisit yang dikelola CLI — **T**

Tanpa refleksi/autoload, migrasi, seeder, provider, command, job, policy, dan listener harus didaftarkan **secara eksplisit** dalam kode. V1 menyebut `withMigrations([...])` tetapi tidak merancang bagaimana `make:migration` menjaga daftar itu tetap sinkron. V2 merancang **registry files** dengan penanda `// dartisan:...` yang diperbarui generator (ADR-002).

#### 2.2.9 Koneksi pool × isolate — **S**

Setiap isolate membuka pool-nya sendiri. `DB_POOL_SIZE=20` dengan 8 isolate = 160 koneksi, melebihi `max_connections` default PostgreSQL (100). V2: konfigurasi `pool.maxPerIsolate` dengan **auto-derivasi** dari `pool.maxTotal / isolates`, dan `dartisan doctor` memperingatkan bila melebihi batas server.

#### 2.2.10 Graceful shutdown dan sinyal — **S**

V1 menyebut graceful shutdown tanpa rincian. `ProcessSignal.sigterm` **tidak didukung di Windows** (hanya `sigint`), isolate pekerja harus di-*drain* (berhenti menerima, menunggu in-flight hingga timeout, menutup pool), dan readiness `/up` harus mengembalikan 503 selama draining agar load balancer berhenti mengirim trafik. V2 merinci urutan ini (Bagian 7.2).

### 2.3 Keamanan

| Temuan | Sev | Keputusan V2 |
| :-- | :-- | :-- |
| `clientIp` tanpa *trusted proxies*; throttle keyed by IP dapat dipalsukan via `X-Forwarded-For` | K | `TrustProxiesMiddleware` dengan daftar CIDR / `*`; tanpa itu header forwarded diabaikan |
| Tidak ada batas ukuran body, jumlah field, kedalaman JSON, ukuran multipart | K | Default: JSON 1 MB, form 1 MB, multipart 10 MB per file / 50 MB total, kedalaman JSON 64; dapat diubah per route |
| Hashing Argon2id/PBKDF2 murni-Dart memblokir event loop isolate HTTP | T | `Hash` berjalan di **worker isolate pool** (`Isolate.run` + pool persisten); ambang biaya terdokumentasi |
| Tidak ada `Crypt` (enkripsi simetris) | T | AES-256-GCM via `package:cryptography`, kunci dari `APP_KEY`, key rotation (`APP_PREVIOUS_KEYS`) |
| Tidak ada otorisasi (Gate/Policy) | T | `Gate.define`, `Policy<T>`, middleware `can:`, `authorize()` di FormRequest |
| Tidak ada CSRF/Session untuk aplikasi web/SPA cookie | S | Tier-2: `Session` store (memory/file/db/redis), encrypted cookies, `VerifyCsrfToken`, Sanctum-style SPA cookie auth |
| Tidak ada security headers, HSTS, CSP | S | `SecurityHeadersMiddleware` default aman untuk API |
| Token Sanctum: pencarian by id lalu perbandingan hash tanpa penegasan *constant-time* | S | Bandingkan `sha256(secret)` dengan `constantTimeEquals`; `last_used_at` diperbarui dengan debounce |
| JWT: tidak ada `nbf`, leeway, `jti`, revokasi, `kid`/rotasi | S | Klaim lengkap, leeway 30 dtk, denylist opsional via cache, dukungan HS256 + EdDSA |
| Tidak ada *signed URLs* dan *temporary signed routes* | S | `URL.signedRoute`, `URL.temporarySignedRoute`, middleware `signed` |
| Query builder: nama kolom dari input user tidak dibahas | S | Identifier **selalu** di-quote; dokumentasi memaksa allow-list untuk `orderBy` dari input |
| Timeouts: slowloris, idle keep-alive, header size | S | `HttpServer.idleTimeout`, header timeout, request timeout per route, batas jumlah header |
| Error response bocorkan stack trace | S | `APP_DEBUG=false` → payload minimal + `error_id` untuk korelasi log |

### 2.4 Kesenjangan Fitur Terhadap Laravel

| Area Laravel | V1 | V2 (tier) |
| :-- | :-- | :-- |
| Routing: constraints, optional param, fallback, 405 + `Allow`, HEAD/OPTIONS otomatis, domain routing, route model binding, signed routes | Sebagian | Lengkap (T1), domain routing (T2) |
| Controllers: resource, apiResource, invokable, controller middleware | Sebagian | Lengkap (T1) |
| Validation: nested/array `*`, `sometimes`, `required_if/unless/with`, `date/after/before`, `url/uuid/ip/json`, `distinct`, closure rule, `bail`, typed `ValidatedData` | Sebagian | Lengkap (T1) |
| Eloquent: save/fill/dirty/casts/accessors/mutators, relasi (hasOne/hasMany/belongsTo/belongsToMany/hasManyThrough), eager loading, withCount, soft deletes, global scopes, observers/events, factories | Minimal | T1 (morph relations T2) |
| Query Builder: groupBy/having/distinct/union/subquery/exists/raw expressions/increment/upsert/chunk/cursor/lock/json where/`when` | ±40% | Lengkap (T1) |
| Schema: alter table (SQLite table-rebuild), index komposit, enum/json/uuid/decimal/date/time, softDeletes, morphs, foreign actions | ±40% | Lengkap (T1) |
| Authorization: Gate, Policy, `can` middleware | Tidak ada | T1 |
| Queue, Jobs, failed_jobs, retries/backoff, `queue:work`, batches | Tidak ada | T1 (sync/database), T2 (redis), T3 (batches) |
| Task Scheduling (`schedule:run/work`, cron, `withoutOverlapping`, `onOneServer`) | Tidak ada | T1 |
| API Resources / JSON transformation | Tidak ada | T1 |
| Pagination: length-aware, simple, cursor | Length-aware saja | T1 |
| Cache: file/db/redis store, tags, locks, `remember`, atomic increments | Memory saja | T1 (file/db/locks), T2 (redis/tags) |
| Session, CSRF, encrypted cookies | Tidak ada | T2 |
| Storage: local, S3-compatible (minio), temporary URLs | Local | T2 |
| Mail (SMTP, templates), Notifications | Tidak ada | T2 (mail), T3 (notifications) |
| Localization (`__()`), pluralization | Tidak ada | T2 |
| Broadcasting / WebSockets / SSE | Tidak ada | T2 (SSE + WS native `dart:io`) |
| HTTP Client facade (`Http::get`), fakes | Tidak ada | T2 |
| Views/Blade | Tidak ada | T3 (mustache + typed HTML builder; posisi API-first) |
| Telescope/Pulse-like observability | Tidak ada | T2: request log, metrics Prometheus, OpenTelemetry traces |
| Octane-equivalent | Implisit | Inti desain (Bagian 5) |

### 2.5 DX & CLI

- **Tidak ada `dartisan new <app>`** — padahal ini pintu masuk pertama. Harus ada, lengkap dengan template, `.env`, Dockerfile, CI.
- `make:*` di V1 tidak menjelaskan **pembaruan registry** (import + daftar) — tanpa itu, generator hanya setengah jalan.
- Tidak ada `dartisan build` (bungkus `dart compile exe` + verifikasi aset + `--define`), `dartisan doctor`, `dartisan about`, `dartisan test`, `dartisan script <file>` (pengganti `tinker`), `dartisan openapi:generate`, `dartisan schema:dump`, `dartisan sanctum:prune`, `dartisan queue:work`, `dartisan schedule:work`.
- `route:list` harus bisa memfilter (`--path=`, `--method=`, `--name=`) dan output JSON untuk tooling.
- Stubs harus **publishable** (`stub:publish`) agar tim menyesuaikan gaya kode.
- Hot reload (bukan hanya restart) dan pesan error kompilasi yang diringkas di terminal.

### 2.6 Proses & Kualitas

- Fase V1 bersifat horizontal (seluruh modul per fase). Risiko integrasi menumpuk di fase 6. V2 memakai **walking skeleton** (HTTP → route → JSON → DB → auth, end-to-end, tipis) di minggu pertama, lalu **vertical slices**.
- Tidak ada **suite konformansi** yang memaku semantik Laravel (format error 422, format paginator, urutan middleware, perilaku `nullable`, `confirmed`, nama kolom timestamp, format token Sanctum). V2 mendefinisikan `conformance/` sebagai test executable yang jadi spesifikasi.
- Tidak ada **benchmark harness** dan target performa relatif. V2 mendefinisikan metodologi (bukan angka fiktif).
- Tidak ada kebijakan **API surface** (class modifiers `final`/`interface`/`base`, `@experimental`), **SemVer**, changelog, deprecation policy.
- Tidak ada **ADR**. V2 menambahkan 15 ADR.

### 2.7 Yang Sudah Benar di V1 dan Dipertahankan

- Enam aturan non-negosiabel (AOT, no mirrors, no build_runner, Zone scope, multi-isolate, strict typing, parameterized SQL).
- Pub workspaces monorepo: `packages/daravel` (core), `packages/dartisan_cli`, `apps/daravel_starter`.
- Radix tree router per metode dengan prioritas static > param > wildcard, dukungan `:id` dan `{id}`.
- Config sebagai kode Dart (bukan YAML/PHP array) — ini justru **keunggulan** AOT: config ter-typecheck saat kompilasi.
- Format respons validasi 422 dan paginator mengikuti JSON Laravel persis.
- Sanctum-style personal access tokens `<id>|<secret>` dengan hash SHA-256 di DB.
- `Request.fake()` untuk test tanpa socket.
- Target developer-experience (contoh `bootstrap/app.dart`, `AuthController`) sebagai *acceptance test* — konsep ini diperluas di V2 menjadi suite konformansi.

---

## 3. Filosofi & Prinsip Desain V2

### 3.1 Tesis: "Ergonomi Laravel, Jaminan Dart"

Laravel menang karena **konvensi yang konsisten, API ekspresif, baterai lengkap, dokumentasi, dan testing yang menyenangkan**. Dart menawarkan hal yang tidak dimiliki PHP: **tipe statis yang kuat, null safety, AOT single-binary, startup milidetik, dan isolate sebagai model konkurensi yang aman**.

Dua jebakan yang harus dihindari:

- **Menyalin magic Laravel secara literal** (atribut dinamis, refleksi, autoload) menghasilkan "Laravel yang lebih buruk": tidak bisa AOT, tidak bisa di-typecheck, lambat.
- **Menyalin kemurnian Dart secara literal** (semua eksplisit, tanpa facade, tanpa konvensi) menghasilkan "shelf yang lebih buruk": verbose, tanpa daya tarik bagi developer Laravel.

Jalan tengah V2: **setiap kenyamanan Laravel diturunkan ulang dari primitif bertipe**. Bila sebuah fitur Laravel tidak bisa diturunkan tanpa refleksi, fitur itu didesain ulang (bukan ditiru) — dan perubahannya didokumentasikan sebagai "deviasi yang disengaja".

### 3.2 Sepuluh Prinsip

| # | Prinsip | Konsekuensi konkret |
| :-- | :-- | :-- |
| P1 | **AOT-first** | Setiap commit di CI harus lolos `dart compile exe` untuk starter app; `dart:mirrors` dilarang oleh lint |
| P2 | **Tanpa magic saat build** | Generics + registry eksplisit + scaffold-time generation. Kode yang terlihat di file adalah kode yang berjalan |
| P3 | **Octane-first** | Singleton = per-isolate dan harus *request-agnostic*; state per-request hanya di Zone/`Request`; "mutable static di `app/` = bug" ditegakkan lint |
| P4 | **Aman secara default** | Default konservatif (limits, trusted proxies kosong, debug off di prod); pelonggaran harus eksplisit dan terlihat di config |
| P5 | **Eksplisit tetapi fluent** | Chaining `.name().middleware()`, named params; string-keyed hanya di tempat developer Laravel mengharapkannya (alias middleware, DSL rule sebagai *sugar*) |
| P6 | **Bertipe di tepi** | `Request` → `ValidatedData` bertipe; baris DB → model bertipe via accessor; config bertipe; param rute di-parse dengan tipe |
| P7 | **Testability sebagai input desain** | Semua service dapat diganti lewat container; fake untuk setiap facade; test HTTP tanpa socket |
| P8 | **Paritas semantik, bukan sintaks** | Format JSON error/paginator, urutan middleware, penamaan kolom, format token: **identik** Laravel. Sintaks menyesuaikan Dart |
| P9 | **Pure Dart dulu** | Pustaka native hanya jika tak terhindarkan (`sqlite3`), terdokumentasi dan diperiksa `dartisan doctor` |
| P10 | **Diukur, bukan diklaim** | Benchmark harness, suite konformansi, ADR; tidak ada klaim performa tanpa angka yang dapat direproduksi |

### 3.3 Anti-Tujuan (apa yang *bukan* Daravel)

- Bukan framework yang bergantung pada Flutter (tetapi dirancang bersinergi dengan Flutter, lihat 4.3).
- Bukan framework berbasis code generation pada build (seperti Serverpod) — generator hanya berjalan di *scaffold-time*.
- Bukan file-based routing (seperti dart_frog) — rute adalah kode eksplisit yang dapat dikomposisi dan di-introspeksi.
- Bukan microframework (seperti shelf/alfred) — baterai lengkap adalah tujuan.
- Bukan monolith view-first (Blade) — API-first; view adalah tier-3 opsional.

### 3.4 Trinitas Ergonomi Tanpa Magic (konsep inti V2)

Masalah fundamental: Laravel mendapatkan ergonominya dari **autoload + refleksi + atribut dinamis**. Ketiganya mustahil di AOT Dart, dan Dart macros (yang semula diharapkan mengisi celah ini) sudah dihentikan. V2 mengganti ketiganya dengan tiga mekanisme yang masing-masing murah, deterministik, dan terlihat:

1. **Generics sebagai pengganti refleksi tipe.** `make<T>()`, `Model<T>`, `Policy<T>`, `Job<T>`, `Resource<T>`, `Events.listen<E>()`. `Type` runtime tetap tersedia di AOT sebagai kunci map (`T` → `Type`), cukup untuk container dan registri tanpa introspeksi anggota.
2. **Registry eksplisit sebagai pengganti autoload.** Semua "hal yang ditemukan otomatis" di Laravel (migrasi, seeder, provider, command, job, policy, listener, model binding) menjadi **daftar Dart biasa** di `bootstrap/`. Daftar ini adalah sumber kebenaran, dapat di-`dart analyze`, dan mustahil "lupa terdaftar tanpa ketahuan" karena generator CLI yang menulisnya (lihat ADR-002).
3. **Scaffold-time generation sebagai pengganti atribut dinamis.** `dartisan make:model Post -m -c -f -p` menulis model dengan accessor bertipe, migrasi, controller, factory, policy, **dan memperbarui registry**. Kode hasil generate adalah Dart polos yang dimiliki developer, bukan artefak `.g.dart` yang harus di-regenerate tiap build. Generator idempoten lewat *marker region* (`// <dartisan:accessors>` … `// </dartisan:accessors>`), sehingga `dartisan model:sync` dapat menyegarkan accessor dari skema DB tanpa menyentuh kode tulisan tangan (serupa `laravel-ide-helper`, tetapi menulis kode nyata).

Perbandingan posisi mekanisme:

| Framework | Kapan "magic" terjadi | Biaya |
| :-- | :-- | :-- |
| Laravel | Runtime (autoload, refleksi, `__get`) | CPU per request, tanpa typecheck |
| Serverpod | Build time (codegen) | Build step wajib, artefak generate |
| dart_frog | Build time (route tree dari file) | `dart_frog build` sebelum deploy |
| **Daravel** | **Scaffold time** (sekali, saat `make:*`) | Nol di build & runtime; kode terlihat |

---

## 4. Lanskap & Posisi Strategis

### 4.1 Peta Kompetitor (status Oktober 2026)

| Framework | Pendekatan | ORM | Codegen | AOT | Status | Pelajaran untuk Daravel |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| `shelf` 1.4.x | Microframework, middleware komposabel | — | Tidak | Ya | Stabil, de-facto standar | Interop: sediakan adapter agar middleware shelf bisa dipasang (ADR-015) |
| `dart_frog` 1.2.x | File-based routing, dev server hot reload | — | Build step | Ya | Aktif (VGV) | Dev server dengan hot reload VM Service adalah standar DX yang diharapkan |
| `serverpod` 4.x | Full-stack, Postgres, generated client untuk Flutter | Ya (generated) | Berat | Ya | Sangat aktif, komersial | Nilai dari *typed client* untuk Flutter; tetapi codegen berat adalah friksi |
| `vania` 2.1.0 | Laravel-flavored, baterai lengkap | Ya | Tidak | Ya | Aktif (rilis 22 Okt 2026) | Validasi permintaan pasar; pelajari gap: concurrency model, testing, Zone tx, OpenAPI |
| `dartian` 1.0.0 | Laravel-inspired (HTTP, DI, ORM, auth, queue) | Ya | ? | ? | Baru (Nov 2025), **AGPL-3.0** | Lisensi AGPL menghambat adopsi komersial → Daravel harus MIT |
| `angel3` 9.x | Full-stack, plugin, ORM via codegen | Ya | Ya | Sebagian | Aktif komunitas | Kompleksitas tinggi & sejarah refleksi = peringatan |
| `conduit` 7.x | Fork aqueduct, ORM | Ya | Ya | Terbatas | Aktif terbatas | Ketergantungan mirrors di masa lalu membunuh AOT |
| `alfred` 1.1.x | Express-like | — | Tidak | Ya | Lambat | Kesederhanaan tanpa baterai tidak cukup |
| `daravel_core` 0.0.3 | Laravel-inspired di atas shelf | QB saja | Tidak | Ya | Mangkrak (2024) | **Konflik nama** — lihat ADR-012 |

### 4.2 Diferensiasi Daravel (apa yang belum ada di pasar)

1. **Model konkurensi Octane-grade yang eksplisit**: cakupan `isolate/process/cluster` untuk setiap store, lint yang menangkap state bocor, koordinasi antar-isolate bawaan.
2. **Active Record ala Eloquent tanpa codegen dan tanpa refleksi**: dirty tracking, casts, relasi, eager loading, observers, soft deletes.
3. **Transaksi sadar-Zone**: `DB.transaction(() async { ... })` dan semua pemanggilan bersarang otomatis ikut koneksi yang sama; savepoint untuk nesting.
4. **Hot reload sungguhan** untuk server (VM Service), bukan restart.
5. **OpenAPI dari introspeksi runtime**: rute + `Rule` + resource → spesifikasi, tanpa anotasi.
6. **Testing toolkit** setara Laravel: `TestClient`, `RefreshDatabase`, fakes, factories, time travel.
7. **Kompatibilitas penyimpanan dengan Laravel** (lihat 4.4): hash bcrypt `$2y$`, tabel `personal_access_tokens`, `migrations`, format `jobs`/`failed_jobs`, format JSON error — memungkinkan **koeksistensi Laravel + Daravel di satu database**.

### 4.3 Sinergi dengan Flutter (peluang strategis)

Tim yang sudah memakai Dart untuk Flutter mendapatkan **satu bahasa end-to-end**. Dua peluang konkret di tier-2/3:

- `dartisan client:generate` menghasilkan **Dart client SDK bertipe** dari OpenAPI yang dihasilkan framework (model DTO + metode per rute), tanpa Serverpod-style coupling: client tetap opsional dan berbasis HTTP standar.
- Paket `daravel_contracts` berisi tipe DTO/validasi yang dapat dibagi antara server dan aplikasi Flutter (validasi yang sama di form Flutter dan di server).

### 4.4 Jalur Migrasi Laravel → Daravel (koeksistensi)

Inovasi posisi: Daravel dirancang agar **bisa berjalan berdampingan dengan aplikasi Laravel yang ada**, berbagi database yang sama, sehingga migrasi dapat dilakukan **per-endpoint**:

| Aspek | Kompatibilitas yang dijamin |
| :-- | :-- |
| Password | `Hash.check` memahami `$2y$` (bcrypt) dan `$argon2id$`; `Hash.make` dapat diset ke bcrypt agar Laravel tetap bisa memverifikasi |
| Token API | Skema `personal_access_tokens` identik Sanctum; format token `id\|secret` dan hash SHA-256 identik → token yang dibuat Laravel valid di Daravel dan sebaliknya |
| Migrasi | Tabel `migrations` (`id`, `migration`, `batch`) identik; Daravel dapat membaca batch Laravel dan melanjutkan penomoran |
| Queue | Skema `jobs`/`failed_jobs` database driver kompatibel; payload berbeda (PHP serialize vs JSON), jadi job **tidak** lintas-runtime — didokumentasikan |
| Respons | Format 422, 401, 403, 404, paginator identik → klien (Flutter/web) tidak tahu backend mana yang menjawab |
| Enkripsi | `Crypt` format kompatibel Laravel (`{"iv","value","mac","tag"}` base64) agar cookie/nilai terenkripsi lintas-runtime (tier-2, perlu AES-256-CBC+HMAC *dan* GCM) |

Ini menjadikan Daravel bukan hanya "framework baru", tetapi **jalur keluar bertahap** bagi tim Laravel yang menginginkan performa dan single-binary — pasar yang konkret dan besar di Indonesia.

---

## 5. Arsitektur Sistem

### 5.1 Lapisan

```text
┌──────────────────────────────────────────────────────────────────┐
│  USER LAND  (apps/<app>)                                         │
│  bootstrap/  config/  routes/  app/{http,models,jobs,policies}   │
│  database/{migrations,seeders,factories}  test/                  │
├──────────────────────────────────────────────────────────────────┤
│  DARAVEL FRAMEWORK  (packages/daravel)                           │
│  foundation : Container · Application · Env · Config · Providers │
│  http       : ServerEngine · Kernel · Request/Response · Pipeline│
│  routing    : Router · RadixTree · RouteEntry · UrlGenerator     │
│  validation : Validator · Rule · FormRequest · ValidatedData     │
│  database   : Driver · Grammar · QueryBuilder · ORM · Schema     │
│  auth       : Guards · Hash · Crypt · Gate/Policy · Tokens       │
│  cache      : Stores · RateLimiter · Locks   events : Dispatcher │
│  queue      : Jobs · Drivers · Worker        schedule: Cron      │
│  storage · mail · logging · observability · resources · testing  │
│  support    : Facades · Helpers · Collections · Str · Carbon-like│
├──────────────────────────────────────────────────────────────────┤
│  dart:io · dart:isolate · dart:async · dart:convert              │
│  postgres · sqlite3 · cryptography · crypto · mime · path        │
└──────────────────────────────────────────────────────────────────┘
```

Paket dalam workspace (ADR-014 — satu paket inti dulu, pecah saat stabil):

| Paket | Isi | Dependensi eksternal |
| :-- | :-- | :-- |
| `packages/daravel` | Inti framework (semua modul tier-1), barrel per modul: `package:daravel/daravel.dart`, `package:daravel/database.dart`, dst. | `crypto`, `cryptography`, `postgres`, `sqlite3`, `mime`, `path`, `meta`, `clock`, `collection` |
| `packages/daravel_test` | Testing toolkit (`TestClient`, fakes, `RefreshDatabase`, factories helper) | `test`, `daravel` |
| `packages/daravel_lints` | Custom lint (`custom_lint`): larang `dart:mirrors`, mutable static di `app/`, raw SQL interpolasi, `print` | `custom_lint_builder`, `analyzer` |
| `packages/dartisan_cli` | CLI global & project runner | `args`, `mason_logger`, `watcher`, `vm_service`, `yaml` |
| `packages/daravel_redis` (T2) | Store cache/queue/lock/session Redis | `redis` |
| `packages/daravel_s3` (T2) | Disk S3-compatible | `minio` |
| `packages/daravel_mail` (T2) | Mailer SMTP | `mailer` |
| `packages/daravel_shelf` (T2) | Adapter dua arah dengan shelf | `shelf` |
| `apps/daravel_starter` | Aplikasi referensi + suite konformansi end-to-end | — |

Aturan dependensi: `daravel` **tidak boleh** bergantung pada `redis`/`minio`/`mailer`/`shelf`; integrasi opsional hidup di paket terpisah agar binary AOT pengguna tidak membawa kode yang tidak dipakai (tree-shaking Dart membantu, tetapi batas paket memperjelas kontrak).

### 5.2 Topologi Proses & Isolate

```text
Process (satu binary AOT)
│
├─ Main Isolate ("supervisor")
│   ├─ parse env/config, validasi konfigurasi (pool math, sqlite constraint)
│   ├─ signal handling (SIGINT; SIGTERM di non-Windows)
│   ├─ Coordinator services (Bagian 7.7): RateLimiter(process), Locks(process),
│   │   Scheduler mutex, metrics aggregation, cache invalidation bus
│   └─ Supervisor: spawn/respawn worker, readiness barrier, drain orchestration
│
├─ HTTP Worker Isolates × N  (N = CPU cores secara default)
│   ├─ createApp() → Application.boot()  (Container, pool DB, router) per isolate
│   ├─ HttpServer.bind(host, port, shared: true)
│   └─ Request Zone per koneksi/request
│
├─ Compute Isolate Pool × M  (default 2; `Isolate.run` fallback)
│   └─ Hash (Argon2id/bcrypt), encode JSON besar, kompresi, image ops
│
└─ Opsional (dijalankan sebagai proses terpisah ATAU isolate internal):
    ├─ Queue Worker Isolates   (`dartisan queue:work` atau `--embed-queue`)
    └─ Scheduler Isolate       (`dartisan schedule:work` atau `--embed-scheduler`)
```

Keputusan desain penting:

- **`createApp()` harus fungsi top-level murni** (dapat dikirim ke `Isolate.spawn`) yang membangun `Application` dari `basePath` + env snapshot. Semua state dibuat *di dalam* isolate; tidak ada objek yang dibagikan.
- **Distribusi koneksi** dilakukan oleh `dart:io` untuk `shared: true` — tidak ada akseptor tunggal yang jadi bottleneck. Keadilan distribusi diukur di benchmark harness (bukan diasumsikan).
- **Protokol koordinator**: pesan bertipe (records/sealed classes) lewat `SendPort`, dengan `correlationId`, timeout (default 50 ms untuk rate-limit, 1 s untuk lock), dan *fail-open vs fail-closed* yang dapat dikonfigurasi per service (rate limiter default **fail-open** dengan log peringatan; lock default **fail-closed**).
- **Respawn**: bila worker mati karena error fatal, supervisor me-respawn dengan backoff eksponensial dan mencatat *crash loop* (≥5 crash/menit → keluar dengan kode non-nol agar orkestrator menangani).
- Mengapa bukan satu isolate per request: biaya spawn + boot per isolate (puluhan ms) jauh melebihi biaya request; isolate dipakai sebagai *worker pool*, bukan *actor per request*.

### 5.3 Siklus Hidup Aplikasi (boot)

1. **Create** — `createApp()` → `ApplicationBuilder` → `Application` (belum boot). Tidak ada I/O di tahap ini (agar `route:list`, test, dan `openapi:generate` murah).
2. **Boot** — urutan ketat dan tercatat di log level `debug`:
   1. `Env.load(basePath)` — `.env` → `.env.{APP_ENV}` → variabel OS (prioritas tertinggi) → `--define` compile-time (fallback terakhir).
   2. `Config` dibangun dari objek Dart bertipe (`AppConfig`, `DatabaseConfig`, …) + overlay env.
   3. Validasi konfigurasi (`ConfigValidator`): `APP_KEY` ada dan 32 byte; pool math; SQLite `:memory:` vs isolates; `APP_DEBUG=false` bila `APP_ENV=production` (peringatan keras bila dilanggar).
   4. `register()` semua provider, lalu `boot()` semua provider (dua fase, seperti Laravel; provider boleh `async`).
   5. Kompilasi rute: bangun Radix tree, resolusi alias middleware, verifikasi keunikan nama rute, pra-komputasi daftar middleware per rute (hindari resolusi per request).
   6. Set **root container** isolate ini; dispatch `ApplicationBooted`.
3. **Serve** — supervisor spawn worker; setiap worker boot (langkah 2) lalu bind; worker melapor `ready`; supervisor menunggu semua ready (timeout 30 s) lalu mencetak banner & URL.
4. **Drain & Shutdown** — sinyal → supervisor broadcast `drain` → setiap worker: `server.close(force: false)` (berhenti menerima), `/up` menjawab 503, tunggu in-flight selesai hingga `SHUTDOWN_TIMEOUT` (default 30 s), jalankan `terminate()` yang tertunda, tutup pool DB & koneksi Redis, kirim `drained` → supervisor keluar kode 0. Setelah timeout, koneksi sisa ditutup paksa dan dicatat.

### 5.4 Siklus Hidup Request (onion)

```text
dart:io HttpRequest
 └─ ServerEngine: batas koneksi, idle/header/request timeout, X-Request-Id
     └─ runZonedGuarded(zoneValues: {container, scope, requestId, tx: null})
         └─ Kernel.handle(Request)
             ├─ Global middleware (urutan tetap, dapat diubah via withMiddleware):
             │   TrustProxies → RequestId → SecurityHeaders → Cors → BodyLimits
             │   → TrimStrings → ConvertEmptyStringsToNull
             ├─ Router.match(method, path) → RouteMatch | NotFound(404) | MethodNotAllowed(405 + Allow)
             ├─ Group middleware → Route middleware (auth, throttle, can, signed, …)
             ├─ Route model binding (explicit binders)
             ├─ FormRequest: authorize() → 403 ; rules() → 422
             └─ Handler → Response | Responsable | Map/List (JSON) | String (text) | null (200 kosong, paritas Laravel)
         ExceptionHandler.render() menangkap di lapisan mana pun → Response
 └─ Tulis respons (status, headers, cookies, body/stream) → flush
 └─ terminate() hooks (setelah respons terkirim) → scope.dispose() → log akses & metrik
```

Catatan semantik:

- `HEAD` otomatis dilayani oleh handler `GET` (body dibuang); `OPTIONS` otomatis menjawab `Allow` + CORS preflight bila `CorsMiddleware` aktif.
- `405` dikembalikan hanya bila path cocok di metode lain (Radix tree di-query lintas metode saat 404 pertama).
- Handler boleh `sync` atau `async` (`FutureOr`), menerima `Request` tunggal; dependensi lain diresolusi lewat `req.make<T>()` atau facade — bukan injeksi parameter (tidak ada refleksi).
- `terminate()` berjalan **setelah** respons ditulis, dalam Zone request yang sama, sehingga `Auth`, `Log` context, dan `scope` masih valid; pekerjaan `defer()` (helper ala Laravel 11) dijadwalkan di sini.

### 5.5 Model Konteks Berbasis Zone

Kunci Zone yang dipakai framework (semua `Symbol` privat; akses hanya lewat API):

| Kunci | Isi | Dibuat oleh |
| :-- | :-- | :-- |
| `#daravel.container` | `Container` aktif | boot (root) / scope |
| `#daravel.scope` | `Scope` (map instance scoped + daftar `onDispose`) | `runScoped` |
| `#daravel.requestId` | `String` | ServerEngine / job worker |
| `#daravel.tx` | `TransactionExecutor` aktif | `DB.transaction` |
| `#daravel.logContext` | `Map<String,Object?>` (ditambah `Log.withContext`) | middleware/handler |
| `#daravel.locale` | `String` | `SetLocale` middleware |

Aturan dan jebakan yang harus dipahami implementor:

1. **Urutan resolusi** `Container.current`: Zone → root per-isolate → `StateError` hanya bila aplikasi belum boot (pesan menjelaskan cara memanggil `boot()`).
2. **Pewarisan Zone pada async gap.** Callback `Future.then`, `Timer`, dan `Stream.listen` berjalan di Zone tempat mereka didaftarkan. Fire-and-forget di dalam request (`unawaited(doSomething())`) akan **menahan** scope hidup setelah respons terkirim. Solusi: `defer(() async {...})` (dieksekusi di `terminate()`), atau `Scope.detached(() => ...)` untuk pekerjaan yang sengaja hidup lebih lama (misal cache warming), yang berjalan di root zone dengan container root.
3. **Error tak tertangani**: setiap request/job dibungkus `runZonedGuarded`; error async yang lolos dirutekan ke `ExceptionHandler.report()` (dicatat dengan `requestId`) dan **tidak** mematikan isolate. Isolate hanya mati pada error di luar scope (bug framework) dan supervisor me-respawn.
4. **Disposal**: `Scope.onDispose(() async {...})` untuk melepaskan resource per-request (file sementara upload, koneksi yang di-checkout, listener). Dipanggil di `finally` setelah `terminate()`.
5. **Biaya**: pembuatan Zone + map scope berorde mikrodetik; lookup `Zone[key]` berjalan menaiki rantai parent (kedalaman ≤ 3 dalam desain ini). Diukur di benchmark harness sebagai `zone_overhead_ns`.
6. **Mode bebas-facade**: setiap facade punya padanan instance yang dapat diakses dari `Request` (`req.app`, `req.db`, `req.auth`, `req.cache`), sehingga tim yang menghindari statik global tetap bisa menulis kode eksplisit; facade hanya *sugar* di atas mekanisme yang sama.

### 5.6 Alur Data Database dalam Transaksi

```text
DB.transaction(() async { await User.create(...); await Post.create(...); })
 └─ DatabaseManager.transaction:
     ├─ jika Zone[#daravel.tx] ada → SAVEPOINT sp_{depth}; callback; RELEASE / ROLLBACK TO
     └─ jika tidak → pool.checkout() → BEGIN → runZoned({#daravel.tx: tx}, callback)
           ├─ commit → COMMIT → pool.release()
           └─ error  → ROLLBACK → pool.release() → rethrow (retry bila deadlock & attempts > 1)
 Semua DB.table()/Model/Rule.unique di dalam callback memanggil DatabaseManager.executor,
 yang membaca Zone[#daravel.tx] lebih dulu — tanpa parameter tx eksplisit.
```

Konsekuensi: koneksi yang di-checkout untuk transaksi **tidak boleh** dipakai dari luar Zone-nya; `TransactionExecutor` menolak penggunaan setelah selesai (`StateError`), dan koneksi selalu dikembalikan di `finally`.

---

## 6. Keputusan Arsitektur (ADR)

### ADR-001 — Resolusi konteks: Zone + root container per-isolate

- **Konteks.** Facade harus bekerja di HTTP, CLI, job, scheduler, dan test. V1 hanya menyediakan Zone request.
- **Opsi.** (a) Zone saja (V1); (b) parameter `Context` eksplisit di semua API (gaya Go); (c) Zone untuk scope + statik per-isolate sebagai root.
- **Keputusan.** (c). `Container.current` = `Zone.current[#daravel.container] ?? Container.root` (statik per-isolate, di-set saat `boot()`). Scope apa pun (request/job/command/test) dibuat lewat satu primitif `Container.runScoped<R>(String name, FutureOr<R> Function() body)`.
- **Konsekuensi.** Facade bekerja di mana saja setelah boot. Test dapat membuat container terisolasi per test case dengan `runScoped`. Statik per-isolate tidak bocor antar isolate. Mode bebas-facade tetap tersedia lewat `Request`/instance.

### ADR-002 — Registry eksplisit yang dirawat oleh CLI (tanpa autoload)

- **Konteks.** AOT tidak dapat menemukan kelas di filesystem. Laravel mengandalkan autoload + konvensi folder.
- **Opsi.** (a) Developer menulis daftar manual; (b) `build_runner` menghasilkan daftar; (c) generator CLI memperbarui daftar lewat marker.
- **Keputusan.** (c). File registry di `bootstrap/`: `providers.dart`, `migrations.dart`, `seeders.dart`, `commands.dart`, `jobs.dart`, `policies.dart`, `listeners.dart`, `bindings.dart`. Setiap file berisi `List<...>` Dart biasa dengan region `// <dartisan:imports>`/`// <dartisan:entries>`. `make:*` menyisipkan import + entri; `dartisan registry:check` memverifikasi tidak ada kelas di folder konvensi yang belum terdaftar (pemindaian sumber sederhana berbasis nama file, bukan refleksi) dan gagal di CI bila ada.
- **Konsekuensi.** Nol magic runtime; tree-shaking optimal; penambahan manual tetap mungkin. Job dan listener diserialisasi berdasar **nama terdaftar** (`JobRegistry.register<SendWelcomeEmail>('SendWelcomeEmail', SendWelcomeEmail.fromJson)`), sehingga rename kelas tidak merusak antrean yang sedang berjalan selama nama registri dipertahankan.

### ADR-003 — Klasifikasi cakupan state: `isolate` / `process` / `cluster`

- **Konteks.** Multi-isolate memecah asumsi "satu proses = satu memori" yang dipegang Laravel+Octane (yang memang tetap *single-threaded per worker* namun berbagi Redis).
- **Opsi.** (a) Abaikan (V1); (b) wajibkan Redis; (c) klasifikasi eksplisit + coordinator isolate untuk `process`.
- **Keputusan.** (c). Setiap store/driver mendeklarasikan `StateScope`. `RateLimiter`, `Cache.lock`, `Schedule.withoutOverlapping`, dan `once()` **wajib** `process` atau `cluster`. `Cache` data biasa boleh `isolate` (dengan dokumentasi "cache per-isolate, bukan sumber kebenaran"). Coordinator isolate melayani `process` scope via `SendPort` request/response dengan timeout dan kebijakan fail-open/fail-closed per service.
- **Konsekuensi.** Perilaku benar secara default pada N isolate tanpa Redis; Redis menjadi pilihan skala-horizontal, bukan prasyarat. Overhead satu hop pesan untuk rate-limit per request (diukur). `--isolates=1` otomatis memakai jalur `isolate` tanpa hop.

### ADR-004 — Topologi: supervisor + worker `shared: true` + compute pool

- **Konteks.** Perlu memanfaatkan semua core, tahan crash, dan tidak memblokir event loop untuk kerja CPU-berat.
- **Opsi.** (a) Satu isolate (sederhana, tidak skala); (b) N isolate independen tanpa supervisor (V1); (c) supervisor + worker + compute pool.
- **Keputusan.** (c), seperti dirinci di 5.2. Default `isolates = Platform.numberOfProcessors`, `compute = 2`. Supervisor **boleh** ikut melayani HTTP bila `isolates = 1` (mode dev/test).
- **Konsekuensi.** Respawn otomatis, readiness barrier, drain terkoordinasi. Kompleksitas protokol pesan; mitigasi lewat tipe pesan `sealed` dan test unit protokol.

### ADR-005 — Grammar mengemit placeholder; raw SQL memakai binding bernama

- **Konteks.** Rewrite `?` → `$n` tekstual rusak pada operator JSONB PostgreSQL dan literal.
- **Opsi.** (a) Regex rewrite (V1); (b) tokenizer SQL penuh; (c) emisi placeholder saat kompilasi AST + named binding untuk raw.
- **Keputusan.** (c). `QueryBuilder` membangun AST (`WhereClause`, `JoinClause`, …) yang dikompilasi oleh `Grammar` dialek; placeholder dibuat oleh `grammar.parameter(i)` (`?` SQLite, `$i` Postgres). `DB.select('select * from t where id = :id', {'id': 1})` memakai tokenizer ringan yang melewati string literal, komentar, `::cast`, dan operator `?`. `DB.raw()` adalah **expression object** (`RawExpression`) yang dilewatkan ke builder tanpa binding kecuali diberi eksplisit.
- **Konsekuensi.** Keamanan injeksi tidak bergantung pada regex; dialek baru (MySQL) hanya menambah `Grammar`. Lint `daravel_lints` menandai interpolasi string ke `DB.select`/`raw`.

### ADR-006 — ORM: Hybrid Active Record tanpa refleksi

- **Konteks.** Model immutable (V1) tidak mampu menyediakan `save()`, dirty tracking, relasi, events. Eloquent dinamis bergantung `__get`/`__set`.
- **Opsi.** (a) Immutable record + repository (V1); (b) attribute bag penuh dinamis (`model['name']`) tanpa tipe; (c) attribute bag + accessor bertipe yang di-generate scaffold + `ModelDefinition<T>` statis.
- **Keputusan.** (c). `abstract base class Model<T extends Model<T>>` menyimpan `Map<String,Object?> _attributes`, `_original`, `_relations`. Developer (atau generator) menulis accessor: `String get name => getAttr('name'); set name(String v) => setAttr('name', v);`. Metadata (`table`, `primaryKey`, `fillable`, `guarded`, `casts`, `hidden`, `appends`, `timestamps`, `softDeletes`, factory konstruktor `User.new`) hidup di `static final definition = ModelDefinition<User>(...)` dan **didaftarkan** di `bootstrap/models.dart` (atau lazy saat pertama dipakai). Query statis `User.query()`, `User.find()`, `User.create()` di-generate oleh `make:model` (tidak bisa diwarisi karena Dart tidak punya *static inheritance*) — 6 baris boilerplate yang dikelola marker region.
- **Konsekuensi.** Paritas Eloquent yang luas (Bagian 7.5.4) dengan tipe di permukaan publik. Biaya: boilerplate kecil yang ter-generate; akses atribut via map (hash lookup) — setara Eloquent, jauh di bawah biaya I/O. Pattern matching Dart tetap bisa dipakai lewat `toRecord()` opsional yang di-generate.

### ADR-007 — Konfigurasi sebagai kode Dart bertipe + overlay dot-notation

- **Konteks.** Laravel memakai array PHP; V1 memakai file Dart. Perlu paritas `config('app.name')` sekaligus typecheck.
- **Keputusan.** Setiap domain config adalah kelas Dart `final` (`AppConfig`, `DatabaseConfig`, `AuthConfig`, `CacheConfig`, `QueueConfig`, …) dengan factory `fromEnv(Env env)`. `ConfigRepository` menyimpan objek bertipe **dan** proyeksi `Map` dot-notation yang dibangun sekali saat boot untuk `Config.get<T>('app.name')`. Pengguna menambah config sendiri lewat `Config.register<MyConfig>(MyConfig.fromEnv)`.
- **Konsekuensi.** Kesalahan tipe/nama terdeteksi saat kompilasi untuk jalur bertipe; jalur string tetap ada untuk kebiasaan Laravel dan untuk paket pihak ketiga. `config:cache` tidak diperlukan (sudah kode).

### ADR-008 — Hashing: multi-driver, format PHC, kompatibel Laravel, di luar event loop

- **Konteks.** PBKDF2 saja (V1) tidak kompatibel dengan ekosistem Laravel dan memblokir isolate HTTP.
- **Keputusan.** `Hash` dengan driver `argon2id` (default; `cryptography` 2.9), `bcrypt` (`bcrypt` 1.2, `$2y$` kompatibel PHP), `pbkdf2` (legacy). Format string PHC standar sehingga `Hash.check` mendeteksi driver dari prefiks dan `Hash.needsRehash` mendukung migrasi bertahap. Semua `make`/`check` dieksekusi di **compute isolate pool** (ADR-004) dengan parameter biaya default: Argon2id `m=64 MiB, t=3, p=1`; bcrypt cost 12; dapat diturunkan di `APP_ENV=testing` untuk mempercepat test.
- **Konsekuensi.** Login tidak memblokir request lain; kompatibilitas dengan DB Laravel yang ada; `dartisan hash:benchmark` membantu memilih parameter biaya di mesin produksi.

### ADR-009 — Hierarki exception & kontrak respons error

- **Konteks.** Perlu format yang identik Laravel agar klien tidak berubah, tetapi juga opsi standar industri.
- **Keputusan.** `sealed class DaravelException` → `HttpException(status, message, headers)` → `NotFoundHttpException`, `UnauthorizedHttpException` (401), `AccessDeniedHttpException` (403), `ValidationException` (422, `errors`), `ThrottleRequestsException` (429, `Retry-After`), `ModelNotFoundException` (→404), `AuthorizationException` (→403), `TokenMismatchException` (419). `ExceptionHandler` mendukung `render<T>()`, `report<T>()`, `dontReport`, `dontFlash`, `level<T>()`, `map<T,U>()`. Format JSON default **identik Laravel** (`{"message": ..., "errors": {...}}`); `APP_DEBUG=true` menambah `exception`, `file`, `line`, `trace`. Opsi `exceptions.format = problemDetails` menghasilkan RFC 9457 (`application/problem+json`). Setiap error 5xx membawa `error_id` (ULID) yang juga ada di log.
- **Konsekuensi.** Klien Laravel-compatible bekerja tanpa perubahan; tim baru dapat memilih RFC 9457. Pola `sealed` memungkinkan exhaustive `switch` di handler kustom.

### ADR-010 — Dev server: hot reload VM Service dengan fallback restart

- **Konteks.** V1 menjanjikan hot-restart; Dart VM mampu hot reload.
- **Keputusan.** `dartisan serve --watch` menjalankan aplikasi sebagai proses anak `dart run --enable-vm-service=0 bin/server.dart`, terhubung ke VM Service (`vm_service` 15.x), dan pada perubahan file memanggil `reloadSources` dengan debounce 300 ms (teknik yang sama dengan `package:hotreloader`). Setelah reload sukses, framework memanggil hook `onHotReload` (rebuild Radix tree dari registry rute, reset cache in-memory bertanda `volatile`). Bila VM menolak reload (perubahan yang tidak didukung, error kompilasi), CLI jatuh ke **restart** penuh dan menampilkan ringkasan error yang dirapikan. Dev server tetap memakai `isolates=1` secara default.
- **Konsekuensi.** Umpan balik sub-detik; koneksi DB dan state dev dipertahankan antar reload. Keterbatasan (inisialisasi `static final` tidak dievaluasi ulang) didokumentasikan; `dartisan serve --watch --restart-only` tersedia.

### ADR-011 — Validasi: objek `Rule` bertipe sebagai primer, DSL string sebagai sugar, `ValidatedData` bertipe

- **Konteks.** `'required|email|max:255'` adalah memori otot developer Laravel, tetapi string tidak ter-typecheck.
- **Keputusan.** Primer: `Rule.required()`, `Rule.email()`, … (objek `const`, dapat di-introspeksi untuk OpenAPI). Sugar: `Rule.parse('required|email|max:255')` di-parse sekali saat definisi (static final) dan menghasilkan objek yang sama; parse gagal → error saat boot/test, bukan saat request. Hasil `validate()` adalah `ValidatedData` (extension type di atas `Map`) dengan `string('email')`, `int('age')`, `maybeString()`, `list<T>()`, `nested('address')`, dan `toMap()`. Path nested `items.*.id` didukung oleh `ValidationContext`.
- **Konsekuensi.** OpenAPI dapat dibangkitkan dari aturan; DX familiar tanpa mengorbankan tipe; pesan error dapat dilokalkan (`lang/id/validation.dart`).

### ADR-012 — Penamaan paket & lisensi

- **Konteks.** `daravel_core` dan `dartisan` sudah terpakai di pub.dev (keduanya mangkrak/placeholder). `vania` aktif; `dartian` AGPL.
- **Keputusan.** Nama paket inti **`daravel`** (tersedia), CLI **`dartisan_cli`** (tersedia) dengan executable bernama `dartisan` (nama executable tidak harus sama dengan nama paket; `dart pub global activate dartisan_cli` mengekspos `dartisan`). Lisensi **MIT**. Sebelum publikasi: hubungi pemilik `dartisan` (placeholder 2017) untuk transfer nama via pub.dev; bila gagal, tetap `dartisan_cli`. Merek "Daravel" diverifikasi tidak bentrok dengan merek dagang terdaftar (tindak lanjut hukum ringan).
- **Konsekuensi.** `import 'package:daravel/daravel.dart';` lebih pendek dari V1; tidak ada risiko sengketa nama dengan proyek 2024.

### ADR-013 — Tier driver database

- **Konteks.** `postgres` 3.5.x pure Dart matang; `sqlite3` 3.7.x FFI sinkron + native lib; `mysql_client` 0.0.27 terakhir 2022.
- **Keputusan.** Tier-1: **PostgreSQL** (produksi) dan **SQLite** (dev/test/embedded). Tier-2: **MySQL/MariaDB** lewat kontrak `DatabaseDriver` yang sama, implementasi memakai `mysql_client` dengan *vendoring fork* bila pemeliharaan upstream berhenti (risiko dicatat di Bagian 13). Grammar MySQL ditulis bersamaan dengan Tier-1 agar permukaan API tidak bias ke Postgres (backtick quoting, `LIMIT ?,?`, `ON DUPLICATE KEY UPDATE`, tanpa `RETURNING` → `LAST_INSERT_ID()`).
- **Konsekuensi.** Pasar Laravel (mayoritas MySQL) terlayani di Tier-2 tanpa redesain; risiko ketergantungan dimitigasi dengan abstraksi driver yang ketat dan suite konformansi DB yang dijalankan terhadap ketiga dialek (SQLite & Postgres di CI; MySQL via container di CI nightly).

### ADR-014 — Tata letak paket: satu inti + satelit opsional

- **Konteks.** Laravel memecah `illuminate/*` menjadi puluhan paket dengan biaya rilis terkoordinasi. Dart tree-shaking mengurangi kebutuhan pemecahan.
- **Keputusan.** Satu paket `daravel` berisi semua modul tier-1 dengan barrel per modul (`package:daravel/http.dart`, `database.dart`, `auth.dart`, …) dan satu barrel utama. Paket satelit hanya untuk dependensi eksternal opsional (`daravel_redis`, `daravel_s3`, `daravel_mail`, `daravel_shelf`) plus `daravel_test`, `daravel_lints`, `dartisan_cli`. Pemecahan inti dipertimbangkan setelah 1.0 bila ada kebutuhan nyata.
- **Konsekuensi.** Versi tunggal, rilis sederhana, impor konsisten; batas modul dijaga oleh aturan impor internal (`src/<modul>` tidak boleh mengimpor `src/<modul lain>` kecuali `foundation`/`support`/`contracts`), ditegakkan oleh test arsitektur (`architecture_test.dart` yang memindai impor).

### ADR-015 — Interop dengan `shelf` & tanda tangan handler

- **Konteks.** Ekosistem middleware Dart terbesar ada di shelf. Developer ingin memakai `shelf_static`, `shelf_proxy`, dsb.
- **Keputusan.** Inti **tidak** dibangun di atas shelf (agar kontrol penuh atas Zone, streaming, timeouts, dan performa). Paket `daravel_shelf` (T2) menyediakan adapter dua arah: `shelfMiddleware(shelf.Middleware)` → `Middleware` Daravel, dan `toShelfHandler(Application)` agar aplikasi Daravel dapat di-mount di server shelf yang ada. Tanda tangan handler Daravel tetap `FutureOr<Object?> Function(Request)`.
- **Konsekuensi.** Reuse ekosistem tanpa mengikat arsitektur inti; biaya konversi `Request`/`Response` hanya di batas adapter.

---

## 7. Spesifikasi Modul yang Diperdalam

Setiap modul dispesifikasikan dengan pola yang sama: **Tujuan → Kontrak API (Dart) → Semantik & edge case → Paritas Laravel & deviasi yang disengaja → Matriks test minimum**. Kontrak di bawah ini adalah kontrak publik yang telah diperbaiki sintaksnya dan boleh disalin oleh implementor.

### 7.1 Foundation

#### 7.1.1 `Container`

```dart
typedef Factory<T extends Object> = T Function(Container c);

final class Container {
  // Kunci binding: (Type, name). name == null → binding default.
  void instance<T extends Object>(T value, {String? name});
  void singleton<T extends Object>(Factory<T> factory, {String? name});   // lazy, per-isolate
  void bind<T extends Object>(Factory<T> factory, {String? name});        // transient
  void scoped<T extends Object>(Factory<T> factory, {String? name});      // per-scope (request/job/command/test)
  void extend<T extends Object>(T Function(T existing, Container c) decorator, {String? name});
  void alias<TAlias extends Object, TTarget extends Object>();
  void tag<T extends Object>(String tag, {String? name});
  List<T> tagged<T extends Object>(String tag);

  bool bound<T extends Object>({String? name});
  T make<T extends Object>({String? name});
  T? tryMake<T extends Object>({String? name});
  void forget<T extends Object>({String? name});
  void resolving<T extends Object>(void Function(T instance, Container c) hook);

  // Scope
  Future<R> runScoped<R>(String scopeName, FutureOr<R> Function(Scope scope) body);
  Scope? get currentScope;

  static Container get current;      // Zone → root → StateError
  static Container? get rootOrNull;
  static void setRoot(Container c);  // hanya dipanggil Application.boot / test harness
}

final class Scope {
  final String name;                 // 'request' | 'job' | 'command' | 'test' | custom
  T? get<T extends Object>({String? name});
  void put<T extends Object>(T instance, {String? name});
  void onDispose(FutureOr<void> Function() callback);
  Future<void> dispose();            // LIFO, error di satu callback tidak menghentikan lainnya (dilaporkan)
}
```

Semantik:

- Resolusi `make<T>`: scope aktif (instance ada → kembalikan; factory `scoped` ada → buat & simpan) → `instances` → `singletons` (lazy; instansiasi **sekali** meski dipanggil re-entrant berkat guard) → `transients` → `BindingResolutionException` dengan pesan yang menyebut tipe, nama, dan scope aktif.
- Deteksi siklus: stack resolusi per-pemanggilan; kedalaman > 64 atau tipe yang sama muncul dua kali → `CircularDependencyException(path)`.
- `singleton` dibuat di isolate pemanggil; **tidak** ada sinkronisasi lintas isolate (by design, ADR-003).
- `scoped` di luar scope aktif: default **error** (`ScopeRequiredException`), bukan diam-diam menjadi singleton. Opsi `fallbackToSingleton: true` tersedia untuk kasus khusus dan tercatat di log debug.
- `resolving` hooks dipanggil setelah instansiasi, sebelum dikembalikan; dipakai untuk `Config`-injection dan dekorasi.

Matriks test: resolusi 4 lifetime; nama/alias/tag; siklus; re-entrant singleton; 1.000 scope paralel (`Future.wait`) tanpa kebocoran instance scoped; `dispose` LIFO dan ketahanan terhadap error; `Container.current` di dalam/luar Zone; isolasi antar isolate (spawn 2 isolate, pastikan singleton berbeda).

#### 7.1.2 `Application` & `ApplicationBuilder`

```dart
final class Application {
  final String basePath;
  final Container container;
  final Env env;
  final ConfigRepository config;
  final Router router;
  bool get booted;
  bool get draining;

  static ApplicationBuilder configure({String? basePath});

  Future<void> boot();                                 // idempoten
  Future<Response> handle(Request request);            // satu request, tanpa socket (dipakai server & TestClient)
  Future<void> serve({ServeOptions? options});         // supervisor + workers
  Future<void> shutdown({Duration? timeout});
  Future<R> runScoped<R>(String scope, FutureOr<R> Function(Scope) body);
  Future<void> terminate();                            // dispatch ApplicationTerminating, tutup resource
}

final class ApplicationBuilder {
  ApplicationBuilder withRouting({
    void Function(Router r)? api, void Function(Router r)? web,
    String apiPrefix = '/api', String? health = '/up',
    List<void Function(Router r)> then = const [],
  });
  ApplicationBuilder withMiddleware(void Function(MiddlewareRegistry m) configure);
  ApplicationBuilder withExceptions(void Function(ExceptionHandler e) configure);
  ApplicationBuilder withProviders(List<ServiceProvider> providers);
  ApplicationBuilder withMigrations(List<Migration> migrations);
  ApplicationBuilder withSeeders(List<Seeder> seeders);
  ApplicationBuilder withCommands(List<Command> commands);
  ApplicationBuilder withJobs(void Function(JobRegistry jobs) register);
  ApplicationBuilder withPolicies(void Function(Gate gate) register);
  ApplicationBuilder withEvents(void Function(EventRegistry events) register);
  ApplicationBuilder withSchedule(void Function(Schedule schedule) define);
  ApplicationBuilder withConfig<T extends Object>(T Function(Env env) factory);
  ApplicationBuilder withEnv(Map<String, String> overrides);   // test/CLI
  Application create();
}
```

`ServeOptions`: `host`, `port`, `isolates`, `computeIsolates`, `backlog`, `idleTimeout`, `headerTimeout`, `requestTimeout`, `maxConnectionsPerIsolate`, `tls: SecurityContext?`, `shutdownTimeout`, `embedQueueWorkers`, `embedScheduler`.

`ServiceProvider`: `register(Container c)`, `boot(Container c)` (keduanya `FutureOr<void>`), `provides` (daftar `Type` untuk *deferred provider* — hanya di-register saat tipe pertama kali diminta), `bootAfter` (urutan eksplisit antar provider, dicek siklus).

#### 7.1.3 `Env`

- Parser `.env` kompatibel format Laravel/dotenv: komentar `#`, kutip tunggal/ganda, escape `\n` di kutip ganda, ekspansi `${VAR}` dan `$VAR`, `export` prefix diabaikan, multiline dalam kutip.
- Prioritas: variabel OS > `.env.{APP_ENV}` > `.env` > `--define` (`String.fromEnvironment`, dibaca via `Env.define('KEY')` yang di-generate sebagai konstanta di `bootstrap/defines.dart` — karena `fromEnvironment` harus `const` dengan nama literal).
- API bertipe: `string('KEY', {default})`, `requireString`, `int`, `bool` (menerima `true/false/1/0/yes/no/on/off`), `duration` (`30s`, `5m`, `1h`), `list` (koma), `url`, `enumValue<E>`. Kesalahan tipe → `EnvException` dengan nama kunci saat boot, bukan `FormatException` tanpa konteks saat runtime.
- `dartisan env:check` membandingkan `.env` dengan `.env.example` (kunci hilang/berlebih).
- `env:encrypt`/`env:decrypt` (AES-256-GCM, kunci di luar repo) — paritas Laravel 9.32+.

#### 7.1.4 `Config`

Lihat ADR-007. Tambahan: `Config.get<T>` melempar `ConfigTypeException` bila tipe tidak cocok (bukan `null` diam); `Config.has`; `Config.set` **hanya** diperbolehkan sebelum boot selesai atau di dalam test (`Config.fake`), setelah itu repository **frozen** (mencegah mutasi lintas request — konsekuensi P3).

### 7.2 HTTP

#### 7.2.1 `ServerEngine`

Tanggung jawab: bind, batas koneksi, timeouts, konversi `HttpRequest` → `Request` (lazy body), penulisan `Response` (termasuk streaming & `Content-Length` otomatis untuk body byte), keep-alive, `X-Request-Id` (terima dari klien bila ada & valid, selain itu ULID), pencatatan akses, dan drain.

Default timeouts: `idleTimeout` 60 s (keep-alive), `headerTimeout` 10 s, `requestTimeout` 30 s (dapat di-override per rute dengan `.timeout(Duration)` untuk upload/stream), batas header 8 KB total, `maxConnectionsPerIsolate` 10.000 (di atas itu → tolak dengan 503 cepat, catat metrik `connections_rejected`).

TLS: `SecurityContext` opsional untuk eksposur langsung; rekomendasi produksi tetap reverse proxy (Caddy/nginx) untuk TLS termination + HTTP/2/3 karena `dart:io` hanya HTTP/1.1. Didokumentasikan sebagai *deployment topology A/B*.

#### 7.2.2 `Request`

```dart
final class Request {
  String get method; Uri get uri; String get path; String get scheme; bool get isSecure;
  Headers get headers;                       // case-insensitive, multi-value, first()/all()
  String? header(String name);
  Map<String, String> get routeParams;       // raw
  T param<T>(String key);                    // typed parse (int/double/bool/String/DateTime/Uuid) → 404 bila gagal
  Map<String, List<String>> get queryMulti;  // ?tags=a&tags=b dan ?tags[]=a
  Map<String, String> get query;
  String get ip;                             // sudah menghormati TrustProxies
  List<String> get ips;
  String? get userAgent; String? get referer; String? get contentType;
  bool get isJson; bool get expectsJson; bool get acceptsHtml; bool get ajax;

  Future<Object?> body();                    // lazy, cached; JSON/form/multipart menurut Content-Type; respek BodyLimits
  Future<List<int>> bytes(); Stream<List<int>> stream();  // raw (satu kali)
  Future<T?> input<T>(String key, [T? fallback]);         // dot-notation; gabungan body + query (body menang)
  Future<ValidatedData> validate(Map<String, List<Rule>> rules, {Map<String, String>? messages, Map<String, String>? attributes});
  Future<Map<String, Object?>> all(); only(List<String>); except(List<String>);
  Future<bool> has(String key); filled(String key); missing(String key);
  Future<UploadedFile?> file(String key); Future<List<UploadedFile>> files(String key);
  String? bearerToken(); Map<String, String> get cookies; String? cookie(String name);

  T make<T extends Object>({String? name});   // container scope aktif
  Scope get scope; String get id;             // request id
  RouteEntry? get route; String? get routeName;
  T? attribute<T>(String key); void setAttribute(String key, Object? value); // per-request bag antar middleware

  Request copyWith({...});                   // untuk middleware yang perlu mengubah (immutable di permukaan)
  static Request fake({String method = 'GET', String path = '/', Object? json, Map<String,String>? form,
      Map<String,String>? headers, Map<String,String>? query, List<FakeFile>? files, String ip = '127.0.0.1'});
}
```

Semantik penting:

- **Body lazy & sekali baca**: `body()` memparse dan mem-cache; `stream()` setelah `body()` → `StateError`. Multipart besar ditulis ke file sementara di `storage/tmp` dengan batas ukuran, dihapus di `scope.dispose()`.
- `ip`: tanpa `TrustProxies`, selalu alamat socket. Dengan trusted proxies: `X-Forwarded-For` diproses **dari kanan** melewati proxy tepercaya (bukan mengambil elemen pertama) — mencegah spoofing.
- `expectsJson`: `Accept: application/json` **atau** `X-Requested-With: XMLHttpRequest` **atau** rute di bawah prefix API (konfigurasi `http.forceJsonUnder = ['/api']`) — menentukan render error JSON vs HTML.

#### 7.2.3 `Response`

```dart
final class Response {
  factory Response.json(Object? data, {int status = 200, Headers? headers, JsonEncoderOptions? options});
  factory Response.created(Object? data, {String? location});
  factory Response.accepted([Object? data]);
  factory Response.noContent();
  factory Response.text(String body, {int status = 200});
  factory Response.html(String html, {int status = 200});
  factory Response.redirect(String location, {int status = 302});
  factory Response.redirectToRoute(String name, {Map<String, Object?> params = const {}, int status = 302});
  factory Response.bytes(List<int> body, {required String contentType, int status = 200});
  factory Response.stream(Stream<List<int>> body, {required String contentType, int status = 200, int? contentLength});
  factory Response.file(String path, {String? downloadName, bool inline = true});   // Range, ETag, Last-Modified, 304
  factory Response.download(String path, {String? name});
  factory Response.eventStream(Stream<ServerSentEvent> events, {Duration? keepAlive}); // SSE
  factory Response.problem(ProblemDetails p);                                          // RFC 9457

  Response withHeader(String name, String value); withHeaders(Map<String,String>);
  Response withCookie(Cookie c); withoutCookie(String name);
  Response withStatus(int status);
  Response cache({Duration? maxAge, bool public = false, bool immutable = false, String? etag});
  Response noCache();
}
```

- JSON encoder memahami `JsonSerializable` (`toJson()`), `Model`, `Resource`, `Paginator`, `DateTime` (ISO-8601 UTC, paritas Laravel `Y-m-d\TH:i:s.u\Z`), `Enum` (`name`), `Uri`, `BigInt`, `Duration` (opsi), `Set`. Encoder besar (> 256 KB) dapat dialihkan ke compute isolate (opsi `offloadThreshold`).
- `Responsable` interface: objek apa pun yang mengimplementasikan `Response toResponse(Request req)` boleh dikembalikan dari handler (dipakai `Resource`, `Paginator`, `View`).

#### 7.2.4 Middleware & Pipeline

```dart
typedef Next = Future<Response> Function(Request req);

abstract interface class Middleware {
  Future<Response> handle(Request req, Next next);
}
abstract interface class TerminableMiddleware implements Middleware {
  Future<void> terminate(Request req, Response res);   // setelah respons terkirim
}

final class MiddlewareRegistry {
  void use(List<Middleware> global);                       // append
  void prepend(Middleware m); void remove<T extends Middleware>();
  void group(String name, List<Object> middleware);        // Middleware | String alias
  void alias(String name, Middleware Function(List<String> params) factory); // 'throttle:60,1'
  void priority(List<Type> order);                         // paritas $middlewarePriority
  void trustProxies({List<String> cidrs = const [], bool all = false, Set<ForwardedHeader> headers});
  void validateCsrfTokens({List<String> except = const []});
  void encryptCookies({List<String> except = const []});
  void bodyLimits({int json = 1 << 20, int form = 1 << 20, int multipartFile = 10 << 20, int multipartTotal = 50 << 20, int jsonDepth = 64});
}
```

Urutan eksekusi: global (urut registrasi, lalu disortir oleh `priority` bila didefinisikan) → grup → rute. `withoutMiddleware<T>()` pada rute menghapus instance tipe tersebut dari rantai. Alias dengan parameter diparse sekali saat kompilasi rute (`'throttle:60,1'` → `ThrottleMiddleware(60, Duration(minutes: 1))`).

Middleware bawaan tier-1: `TrustProxies`, `RequestId`, `SecurityHeaders`, `Cors` (konfigurasi `allowedOrigins` pola/regex, `allowedMethods`, `allowedHeaders`, `exposedHeaders`, `maxAge`, `supportsCredentials`; preflight dijawab tanpa menyentuh router), `BodyLimits`, `TrimStrings`, `ConvertEmptyStringsToNull`, `Authenticate` (`auth`, `auth:jwt`), `Authorize` (`can:update,post`), `Throttle` (`throttle:60,1`, `throttle:api` → named limiter), `ValidateSignature` (`signed`), `SetLocale`, `EnsureJsonAccepts` (`json`), `Compress` (gzip/br untuk respons > 1 KB bila klien menerima; br via pure Dart tidak tersedia → gzip saja di tier-1), `ETag`, `RequestLogger`.

#### 7.2.5 `ExceptionHandler`

Lihat ADR-009. Tambahan API: `renderable`, `reportable` closures; `withRequestId`; `ignore<T>()`; `context(() => {...})` untuk menambah konteks laporan (user id, route); integrasi `Log` + `Observability` (error dihitung sebagai metrik `http_errors_total{status}`); `dontReportDuplicates` (dedup per `errorHash` 1 menit).

### 7.3 Routing

#### 7.3.1 Radix Tree

- Satu pohon per metode HTTP, node bertipe `static | param | wildcard`, dengan **kompresi prefix** untuk segmen statik (benar-benar radix, bukan sekadar trie per segmen) agar `/api/v1/users` dan `/api/v1/usage` berbagi prefix.
- Prioritas saat matching: static > param > wildcard, **backtracking** terbatas: bila jalur static buntu, coba param, lalu wildcard (dibutuhkan untuk `/users/new` vs `/users/{id}/edit`).
- Constraint param dievaluasi saat matching (`where('id', r'\d+')`, `whereNumber`, `whereUuid`, `whereIn(['a','b'])`), sehingga `/users/abc` jatuh ke rute lain bila ada, bukan langsung 404.
- Param opsional `{slug?}` di-ekspansi menjadi dua rute saat kompilasi. Wildcard `{path*}`/`*path` hanya di segmen terakhir.
- Trailing slash: dinormalisasi (`/users/` ≡ `/users`) dengan opsi `strictTrailingSlash`.
- Kompleksitas: O(panjang path) per lookup, nol alokasi untuk rute statik (hasil pra-komputasi), satu `Map` kecil untuk param.
- 405: saat tidak cocok, pohon metode lain diperiksa; hasil dikumpulkan ke header `Allow`.

#### 7.3.2 `Router` & `RouteEntry`

```dart
typedef Handler = FutureOr<Object?> Function(Request req);

final class Router {
  RouteEntry get(String path, Handler h); post(...); put(...); patch(...); delete(...); options(...);
  RouteEntry match(List<String> methods, String path, Handler h); any(String path, Handler h);
  RouteEntry redirect(String from, String to, {int status = 302}); permanentRedirect(String from, String to);
  RouteEntry view(String path, String view, {Map<String, Object?> data = const {}});     // T3
  RouteEntry fallback(Handler h);

  RouteGroup group(void Function(Router r) routes, {String prefix = '', String name = '', List<Object> middleware = const [],
      String? domain, Map<String, String> where = const {}});
  RouteGroup prefix(String p); name(String n); middleware(List<Object> m); domain(String d); controller(Object c);  // fluent → .group()

  void apiResource(String name, ResourceController c, {List<String>? only, List<String>? except, Map<String,String>? parameters, bool shallow = false});
  void resource(String name, ResourceController c, {...});     // + create/edit (web, T3)
  void apiResources(Map<String, ResourceController> map);
  void singleton(String name, SingletonController c);           // profile, settings

  void bind<T extends Object>(String param, Future<T?> Function(String value, Request req) resolver, {bool orFail = true});
  void model<T extends Model<T>>(String param, ModelDefinition<T> def, {String? column});
  void pattern(String param, String regex);                       // global constraint

  String url(String name, {Map<String, Object?> params = const {}, Map<String, Object?> query = const {}, bool absolute = true});
  String signedUrl(String name, {Map<String, Object?> params = const {}, Duration? expires});
  bool has(String name);
  List<RouteEntry> get routes;                                    // introspeksi untuk route:list & OpenAPI
}

final class RouteEntry {
  RouteEntry name(String n); middleware(List<Object> m); withoutMiddleware<T extends Middleware>();
  RouteEntry where(String param, String regex); whereNumber(String p); whereUuid(String p); whereAlpha(String p); whereIn(String p, List<String> v);
  RouteEntry timeout(Duration d); bodyLimit(int bytes);
  RouteEntry scopeBindings();                                    // nested binding (post milik user)
  RouteEntry summary(String s); tags(List<String> t); responses(Map<int, Object> schema); // metadata OpenAPI, opsional
  RouteEntry defaults(Map<String, Object?> values);
}
```

- `handler` mengembalikan `Object?`; konversi otomatis sesuai 5.4. Controller method adalah *tear-off* biasa (`userController.show`), jadi tidak perlu string `'UserController@show'`.
- Route model binding eksplisit: `router.model<User>('user', User.definition)` → `req.param<User>('user')` atau `req.model<User>('user')`; nested `scopeBindings()` memaksa `posts.user_id = users.id` lewat relasi yang dideklarasikan di `ModelDefinition.relations`.
- `route:list` membaca `router.routes` dan metadata; `openapi:generate` membaca metadata + `FormRequest` yang dideklarasikan lewat `RouteEntry.validates<RegisterRequest>(RegisterRequest.new)` (opsional, untuk dokumentasi; validasi tetap di handler).
- Paritas Laravel: nama default `apiResource('posts')` → `posts.index|store|show|update|destroy`, param `{post}`; `shallow`, `only`, `except`, `parameters` identik.

Matriks test: prioritas static/param/wildcard; backtracking; constraint; optional; 405 + `Allow`; HEAD/OPTIONS otomatis; group bersarang (prefix/name/middleware/where bertumpuk); `url()` dengan param & query & encoding; signed URL & kedaluwarsa; `apiResource` nama & param; binding sukses/404/scoped; 10.000 rute acak vs implementasi referensi linear (property test).

### 7.4 Validation

#### 7.4.1 Kontrak

```dart
abstract class Rule {
  const Rule();
  String get name;                                   // 'required', 'email', … (dipakai pesan & OpenAPI)
  bool get implicit => false;                        // berjalan meski nilai null/absen (required*, present, sometimes)
  FutureOr<String?> passes(ValidationContext ctx);   // null = lolos; string = kunci pesan atau pesan literal
  OpenApiSchemaHint? get schemaHint => null;         // introspeksi (type/format/min/max/enum/pattern)
}

final class ValidationContext {
  final String attribute;       // 'items.2.id'
  final String pattern;         // 'items.*.id'
  final Object? value;
  final Map<String, Object?> data;    // root
  final Container container;    // untuk unique/exists
  final String locale;
  Object? sibling(String key);  // 'items.2.qty' relatif
  Object? root(String path);
}

final class Validator {
  Validator(Map<String, Object?> data, Map<String, List<Rule>> rules, {Map<String, String>? messages, Map<String, String>? attributes, bool bail = false});
  Future<ValidatedData> validate();              // throw ValidationException
  Future<bool> passes(); Future<bool> fails();
  Future<ValidationErrors> errors();
  Validator sometimes(String field, List<Rule> rules, bool Function(Map<String, Object?> data) when);
  Validator after(FutureOr<void> Function(Validator v) hook);
}

abstract class FormRequest {
  FutureOr<bool> authorize(Request req) => true;
  Map<String, List<Rule>> rules(Request req);
  Map<String, String> messages() => const {};
  Map<String, String> attributes() => const {};
  Future<Map<String, Object?>> prepare(Request req, Map<String, Object?> input) async => input;   // prepareForValidation
  Future<ValidatedData> passed(ValidatedData data) async => data;                                 // passedValidation
  static Future<ValidatedData> run<T extends FormRequest>(T form, Request req);                   // authorize → 403; validate → 422
}
```

Penggunaan: `final data = await FormRequest.run(RegisterRequest(), req);` atau di rute `r.post('/register', validated(RegisterRequest.new, controller.register))` (helper yang menjalankan form lalu memanggil handler dengan `(req, data)`).

#### 7.4.2 Katalog aturan tier-1

`required`, `nullable`, `sometimes`, `present`, `filled`, `prohibited`, `required_if/unless/with/with_all/without/without_all`, `prohibited_if/unless`, `exclude_if/unless`, `bail` (per-field), `string`, `integer`, `numeric`, `boolean` (menerima `true/false/1/0/"1"/"0"/"true"/"false"`), `list`, `map`, `date` (ISO-8601 + format kustom), `date_format`, `after/after_or_equal/before/before_or_equal` (nilai atau nama field), `email` (RFC 5322 praktis + opsi `dns` tier-2), `url`, `uuid`, `ulid`, `ip/ipv4/ipv6`, `json`, `alpha/alpha_num/alpha_dash`, `ascii`, `regex/not_regex`, `min/max/between/size` (num: nilai; string: panjang karakter (rune); list/map: jumlah; file: KB), `digits/digits_between`, `in/not_in` (dengan `Rule.enumValues<E>()` untuk enum Dart), `distinct`, `confirmed`, `same/different`, `starts_with/ends_with`, `lowercase/uppercase`, `file/image/mimes/mimetypes/max_file_size/dimensions`, `unique(table, column, {ignore, ignoreColumn, where})`, `exists(table, column, {where})`, `array_keys` (`Rule.keys(['a','b'])`), `closure` (`Rule.custom((ctx) => ...)`), `password` (`Rule.password(min: 8, letters: true, mixedCase: true, numbers: true, symbols: true, uncompromised: false)` — `uncompromised` via k-anonymity HIBP tier-2).

Semantik yang harus identik Laravel (dipaku di suite konformansi): `nullable` menghentikan aturan berikutnya bila `null`; field tidak ada dan tidak `required` → aturan non-implicit **dilewati**; `confirmed` mencari `{field}_confirmation`; pesan default sama persis dengan `resources/lang/en/validation.php` (diterjemahkan ke `id` sebagai bahasa kedua bawaan); format `:attribute`, `:min`, `:max`, `:other`, `:values` di pesan.

#### 7.4.3 `ValidatedData`

Extension type di atas `Map<String, Object?>` dengan accessor bertipe yang melempar `StateError` deskriptif bila tipe tidak sesuai (seharusnya tidak terjadi setelah validasi): `string`, `maybeString`, `int`, `double`, `num`, `bool`, `dateTime`, `list<T>`, `map`, `nested(path)`, `file`, `only`, `except`, `toMap`, `toJson`. Nilai yang **tidak divalidasi tidak masuk** (paritas `$request->validated()`), termasuk kunci nested yang tak disebut.

Matriks test: tiap aturan (positif/negatif/edge null/empty/tipe salah), nested `*` dengan 3 level, `sometimes`, `bail`, pesan kustom & atribut, lokal `id`, `unique` dengan `ignore` di dalam transaksi, FormRequest authorize false → 403 sebelum validasi, format 422.

### 7.5 Database

#### 7.5.1 Driver & Pool

```dart
abstract interface class QueryExecutor {
  SqlDialect get dialect;
  Future<QueryResult> query(String sql, [List<Object?> bindings = const []]);  // rows + affectedRows + lastInsertId?
  Future<int> execute(String sql, [List<Object?> bindings = const []]);
  Stream<Map<String, Object?>> cursor(String sql, [List<Object?> bindings = const []]);  // streaming
}
abstract interface class TransactionExecutor implements QueryExecutor {
  int get depth; bool get completed;
}
abstract interface class DatabaseDriver implements QueryExecutor {
  Future<void> connect(); Future<void> close(); Future<bool> ping();
  Future<T> transaction<T>(Future<T> Function(TransactionExecutor tx) body, {IsolationLevel? isolation});
  Future<T> savepoint<T>(TransactionExecutor tx, Future<T> Function(TransactionExecutor tx) body);
  PoolStats get stats;
}
```

- **PostgreSQL** (`postgres` 3.5.x): `Pool` per isolate dengan `maxPerIsolate` (default `max(2, maxTotal ~/ isolates)`), `connectTimeout`, `queryTimeout`, `idleTimeout`, SSL mode (`disable/require/verify-full`), `applicationName='daravel'`, `statement_timeout` per sesi dari config, `search_path`. Tipe: `int/bigint/numeric` (→ `num`/`BigInt`/`Decimal` string), `timestamptz` (→ `DateTime` UTC), `jsonb` (→ `Map/List`), `uuid` (→ `String`), `bytea` (→ `Uint8List`), array (→ `List`). Deadlock `40P01` dan serialization `40001` → retry bila `attempts > 1`.
- **SQLite** (`sqlite3` 3.7.x): satu koneksi per isolate (SQLite single-writer); `PRAGMA journal_mode=WAL; busy_timeout=5000; foreign_keys=ON; synchronous=NORMAL`. Operasi sinkron dibungkus `Future.sync` — didokumentasikan sebagai blocking; opsi `sqlite.offload=true` mengeksekusi di compute isolate khusus (satu isolate DB, pesan request/response) untuk aplikasi yang membaca file SQLite besar.
- **MySQL** (T2) lewat kontrak yang sama.
- `DatabaseManager`: multi-koneksi bernama (`DB.connection('reporting')`), `executor` sadar Zone (5.6), `listen((QueryExecuted e) {...})` untuk logging query lambat (`slowQueryThreshold`), `enableQueryLog()` untuk test, `pretend()` untuk melihat SQL migrasi.

#### 7.5.2 Grammar

```dart
abstract class Grammar {
  String parameter(int index);                              // '?' | '$3'
  String wrap(String identifier);                           // "users"."id" | `users`.`id`; mendukung alias "x as y", "*", "t.*"
  String compileSelect(QueryAst q); compileInsert(...); compileInsertGetId(...); compileUpdate(...); compileDelete(...); compileUpsert(...);
  String compileExists(...); compileTruncate(...); compileLock(LockMode m);
  String compileJsonPath(String column, String path);       // users->meta->>theme
  bool get supportsReturning; bool get supportsSavepoints; bool get supportsUpsert;
  String get dateFormat;                                    // 'yyyy-MM-dd HH:mm:ss' (paritas Laravel)
}
```

Keamanan identifier: `wrap` **menolak** identifier dengan karakter di luar `[A-Za-z0-9_.*]` (melempar `InvalidIdentifierException`) — sehingga `orderBy(req.query['sort'])` yang ceroboh gagal cepat alih-alih menjadi injeksi. Kolom dari input tetap wajib allow-list (dokumentasi + contoh `Rule.inList`).

#### 7.5.3 `QueryBuilder`

Permukaan API tier-1 (paritas `Illuminate\Database\Query\Builder` yang lazim):

- Select: `select`, `selectRaw(sql, bindings)`, `addSelect`, `distinct`, `selectSub(builder, alias)`, `from`, `fromSub`, `fromRaw`.
- Where: `where(col, [op], val)` (2 arg → `=`), `where(Map)`, `where((q) => ...)` grup bersarang, `orWhere*`, `whereNot`, `whereIn/NotIn` (list **atau** sub-query; list kosong → `0 = 1` paritas), `whereNull/NotNull`, `whereBetween/NotBetween`, `whereColumn`, `whereDate/Month/Day/Year/Time`, `whereExists/NotExists`, `whereRaw`, `whereJsonContains`, `whereJsonLength`, `whereLike/NotLike` (case-insensitive opsional), `whereAny/whereAll`, `whereFullText` (T2).
- Join: `join`, `leftJoin`, `rightJoin`, `crossJoin`, `joinSub`, join closure dengan `on/orOn/where`.
- Agregasi & group: `groupBy`, `groupByRaw`, `having`, `havingRaw`, `havingBetween`, `count`, `sum`, `avg`, `min`, `max`, `exists`, `doesntExist`.
- Order/limit: `orderBy`, `orderByDesc`, `orderByRaw`, `latest`, `oldest`, `inRandomOrder`, `reorder`, `limit/take`, `offset/skip`, `forPage`, `forPageBeforeId/AfterId`.
- Eksekusi: `get()`, `first()`, `firstOrFail()`, `sole()`, `find(id)`, `value(col)`, `pluck(col, [key])`, `paginate`, `simplePaginate`, `cursorPaginate`, `chunk(n, cb)`, `chunkById`, `lazy()`/`cursor()` (Stream), `each`.
- Tulis: `insert(Map|List<Map>)`, `insertGetId`, `insertOrIgnore`, `insertUsing`, `upsert(rows, uniqueBy, update)`, `update`, `updateOrInsert`, `increment/decrement` (dengan kolom ekstra), `delete`, `truncate`.
- Lain: `when(cond, cb, [else])`, `unless`, `tap`, `clone()`, `toSql()`, `toRawSql()` (binding disisipkan **hanya untuk debug**, dengan quoting), `dd()`/`dump()` → log, `lockForUpdate`, `sharedLock`, `union/unionAll`, `useWritePdo` (→ `useConnection`).
- `Expression`: `DB.raw('count(*) as total')` adalah tipe `RawExpression`, bukan `String`, sehingga `where('x', DB.raw(...))` tidak di-bind.

Builder bersifat **mutable dengan `clone()`** (paritas Laravel; immutable builder memperlambat chaining dan membingungkan pengguna Laravel) — dokumentasi menekankan `clone()` saat satu builder dipakai dua kali.

Paginator: `LengthAwarePaginator` JSON **identik** Laravel (`current_page, data, first_page_url, from, last_page, last_page_url, links, next_page_url, path, per_page, prev_page_url, to, total`), `SimplePaginator`, `CursorPaginator` (cursor base64 dari kolom order; wajib `orderBy` unik).

#### 7.5.4 ORM — Hybrid Active Record

```dart
abstract base class Model<T extends Model<T>> implements JsonSerializable, Responsable {
  ModelDefinition<T> get definition;         // di-generate: `@override ModelDefinition<User> get definition => User.definition;`
  Map<String, Object?> get attributes; Map<String, Object?> get original;
  R getAttr<R>(String key); void setAttr(String key, Object? value);
  bool get exists; bool get wasRecentlyCreated; Object? get key;
  bool isDirty([String? key]); bool isClean([String?]); bool wasChanged([String?]); Map<String, Object?> getDirty();
  T fill(Map<String, Object?> attrs); T forceFill(Map<String, Object?> attrs);
  Future<bool> save({bool touch = true}); Future<bool> update(Map<String, Object?> attrs); Future<bool> delete(); Future<bool> forceDelete(); Future<bool> restore();
  Future<T> refresh(); Future<T> fresh(); Future<void> touch(); Future<T?> load(List<String> relations); Future<T> loadMissing(List<String>);
  Future<int> increment(String col, [num by = 1]); decrement(...);
  bool get trashed; T replicate({List<String> except});
  bool relationLoaded(String name); R? relation<R>(String name);
  Map<String, Object?> toMap(); Map<String, Object?> toJson();   // hidden/visible/appends/casts/relasi termuat
  T makeVisible(List<String>); makeHidden(List<String>); append(List<String>);
  bool is(T other); isNot(T other);
}

final class ModelDefinition<T extends Model<T>> {
  const ModelDefinition({
    required this.table, required this.factory,                    // factory: T Function() → User.new
    this.primaryKey = 'id', this.keyType = KeyType.autoInt,         // autoInt | uuid | ulid | string
    this.connection, this.fillable = const [], this.guarded = const ['*'],
    this.casts = const {}, this.hidden = const [], this.visible = const [], this.appends = const [],
    this.timestamps = true, this.createdAt = 'created_at', this.updatedAt = 'updated_at',
    this.softDeletes = false, this.deletedAt = 'deleted_at',
    this.relations = const {}, this.scopes = const {}, this.globalScopes = const [],
    this.accessors = const {}, this.mutators = const {}, this.observers = const [],
    this.perPage = 15, this.touches = const [],
  });
}
```

- **Casts**: `int, double, bool, string, datetime, date, json (Map/List), encrypted, enum<E>(values), custom<T>(CastHandler<T>)` — handler bertipe `(get: Object? → T, set: T → Object?)`. `Decimal` via string untuk presisi.
- **Accessors/mutators** tanpa refleksi: `accessors: {'full_name': (m) => '${m.getAttr('first')} ${m.getAttr('last')}'}` untuk kolom virtual (masuk `appends`); accessor Dart biasa (`String get fullName`) juga boleh, tetapi tidak terlihat oleh `toJson` kecuali masuk `appends` lewat peta.
- **Relasi** (dideklarasikan di `relations` sebagai objek, bukan metode magic): `HasOne<Post>`, `HasMany<Post>`, `BelongsTo<User>`, `BelongsToMany<Role>(pivot: 'role_user', withPivot: [...], withTimestamps)`, `HasManyThrough`, `HasOneThrough`, `MorphOne/MorphMany/MorphTo/MorphToMany` (T2). Akses: `user.hasMany<Post>('posts')` mengembalikan `Relation<Post>` yang sekaligus query builder (`.where(...).get()`), `user.related<List<Post>>('posts')` untuk hasil termuat; generator membuat getter bertipe `List<Post> get posts`.
- **Eager loading**: `User.query().with(['posts', 'posts.comments', 'profile'])`, `with({'posts': (q) => q.where('published', true)})`, `withCount`, `withSum/withAvg/withMax/withMin`, `withExists`, `whereHas/orWhereHas/whereDoesntHave/has/doesntHave` (sub-query `EXISTS`), `withWhereHas`. Strategi: *batched WHERE IN* dengan chunk 1.000 kunci (hindari batas parameter: Postgres 65.535, SQLite 32.766), pencocokan di memori dengan `Map` berindeks kunci. Lazy loading tetap aktif (paritas Laravel); `Model.preventLazyLoading()` tersedia dan **diaktifkan di starter untuk non-production** (praktik Laravel modern).
- **Scopes**: lokal `scopes: {'published': (q) => q.where('published', true)}` → `Post.query().scope('published')` dan generator membuat `.published()` extension; global scopes sebagai objek `GlobalScope` (`apply(builder)`), `withoutGlobalScope<T>()`.
- **Events/Observers**: `retrieved, creating, created, updating, updated, saving, saved, deleting, deleted, restoring, restored, forceDeleting, forceDeleted, replicating`; observer = kelas dengan metode opsional (`creating(User u)`), terdaftar di `observers` atau `bootstrap/observers.dart`; event dapat `return false` untuk membatalkan (paritas); `withoutEvents`, `saveQuietly`.
- **Timestamps** UTC, format grammar; `touches` relasi induk; **soft deletes** dengan global scope otomatis, `withTrashed/onlyTrashed`.
- **UUID/ULID keys**: `keyType: KeyType.uuid` → digenerate client-side saat `creating` (`uuid` 4.6 v4/v7; ULID implementasi internal 26 char Crockford).
- **Serialisasi**: `toJson` menghormati `hidden/visible/appends`, relasi termuat (snake_case nama relasi), `DateTime` ISO-8601; `Model` juga `Responsable` sehingga `return user;` dari handler → JSON.
- **Koleksi**: `ModelCollection<T>` (extends `List<T>` delegasi) dengan `pluck`, `keyBy`, `groupBy`, `load`, `toJson`, `modelKeys`, `fresh`, `makeHidden`.
- **Mass assignment**: `fillable` **atau** `guarded`; `create()` lewat `fill` → `MassAssignmentException` bila atribut terlarang dan `Model.preventSilentlyDiscarding` aktif (default di starter non-production), selain itu dibuang diam-diam (paritas).

Kode statis yang di-generate `make:model` (region marker, ±10 baris):

```dart
final class User extends Model<User> implements Authenticatable {
  static const definition = ModelDefinition<User>(table: 'users', factory: User.new, fillable: ['name', 'email', 'password'], hidden: ['password', 'remember_token'], casts: {'email_verified_at': Cast.dateTime});
  @override ModelDefinition<User> get definition => definition;
  // <dartisan:statics>
  static ModelQuery<User> query() => ModelQuery<User>(definition);
  static Future<User?> find(Object id) => query().find(id);
  static Future<User> findOrFail(Object id) => query().findOrFail(id);
  static Future<User> create(Map<String, Object?> attrs) => query().create(attrs);
  static Future<List<User>> all() => query().get();
  static ModelQuery<User> where(String col, Object? op, [Object? val]) => query().where(col, op, val);
  // </dartisan:statics>
  // <dartisan:accessors>
  int get id => getAttr('id'); String get name => getAttr('name'); set name(String v) => setAttr('name', v);
  String get email => getAttr('email'); set email(String v) => setAttr('email', v);
  DateTime? get emailVerifiedAt => getAttr('email_verified_at');
  // </dartisan:accessors>
}
```

Catatan: `ModelQuery<T>` membungkus `QueryBuilder` dan mengembalikan `T`/`List<T>`/`ModelCollection<T>`; semua metode builder tersedia melalui delegasi eksplisit (bukan `noSuchMethod`, yang tidak AOT-friendly untuk tipe dan memperlambat).

#### 7.5.5 Schema & Migrasi

```dart
abstract class Migration {
  const Migration();
  String get name;                 // '2026_10_23_000001_create_users_table' (di-generate)
  bool get withinTransaction => true;   // DDL transaksional di Postgres/SQLite; MySQL false
  Future<void> up(SchemaBuilder schema);
  Future<void> down(SchemaBuilder schema);
}
```

`Blueprint` kolom: `id`, `uuid`, `ulid`, `foreignId`, `foreignUuid`, `string(len)`, `char`, `text/mediumText/longText`, `integer/tinyInteger/smallInteger/bigInteger` (+`unsigned`), `decimal(p,s)`, `float/double`, `boolean`, `date/dateTime/dateTimeTz/time/timestamp/timestampTz/year`, `json/jsonb`, `binary`, `enum(values)` (CHECK constraint di Postgres/SQLite), `ipAddress`, `macAddress`, `geometry` (T3), `timestamps/timestampsTz`, `softDeletes`, `rememberToken`, `morphs/nullableMorphs/uuidMorphs`. Modifier: `nullable`, `default`, `defaultRaw`, `unique`, `index`, `primary`, `comment`, `after` (MySQL), `first`, `useCurrent`, `useCurrentOnUpdate`, `storedAs/virtualAs` (T2), `change()` untuk alter.

Tabel: `create`, `table` (alter), `drop`, `dropIfExists`, `rename`, `hasTable`, `hasColumn`, `getColumns` (introspeksi untuk `model:sync`), index komposit `index(['a','b'])`, `unique([...])`, `fullText` (T2), `foreign('x').references('id').on('t').onDelete('cascade')`, `dropForeign`, `dropIndex`, `dropColumn`, `renameColumn`.

**SQLite alter table**: `dropColumn`, `renameColumn`, `change`, `dropForeign` diimplementasikan lewat **table-rebuild** (buat tabel baru, salin, drop, rename, bangun ulang index) dengan `PRAGMA foreign_keys=OFF` di dalam transaksi — persis strategi doctrine/dbal yang dipakai Laravel. Harus diuji terpisah karena rawan.

`Migrator`: tabel `migrations(id, migration, batch)`; `migrate [--step] [--pretend] [--force]`, `rollback [--step=N] [--batch=N]`, `reset`, `refresh`, `fresh [--seed]` (drop semua tabel via introspeksi dialek), `status`, `migrate:install`; lock migrasi (`process`/`cluster` lock) agar dua instance tidak migrasi bersamaan; `--force` wajib di `production` (paritas).

`schema:dump` menghasilkan `database/schema/<conn>-schema.sql` untuk *squash*; `migrate --schema` memuatnya lebih dulu.

#### 7.5.6 Seeder & Factory

```dart
abstract class Seeder { Future<void> run(SeederContext ctx); Future<void> call(List<Seeder> seeders); }
final class Factory<T extends Model<T>> {
  Factory(ModelDefinition<T> def, Map<String, Object?> Function(Faker f) definition);
  Factory<T> count(int n); state(Map<String, Object?> Function(Faker f) s); sequence(List<Map<String,Object?>>);
  Factory<T> has<R extends Model<R>>(Factory<R> related, String relation); forRelation<R extends Model<R>>(T Function() parent, String relation);
  Factory<T> afterMaking(void Function(T m)); afterCreating(Future<void> Function(T m));
  T make(); List<T> makeMany(); Future<T> create(); Future<List<T>> createMany();
  Map<String, Object?> raw();
}
```

`Faker` internal minimal (nama, email unik, kalimat, angka, tanggal, uuid, pilihan) dengan seed deterministik per test (`Faker.seed(42)`) — tanpa dependensi eksternal; paket `faker` pihak ketiga dapat dipasang lewat adapter.

Matriks test DB (dijalankan terhadap SQLite **dan** Postgres di CI; MySQL nightly): kompilasi SQL per grammar (snapshot test), binding tidak pernah ter-interpolasi (property test dengan payload injeksi), transaksi bersarang & rollback savepoint, Zone propagation lintas `await`, deadlock retry, pagination 3 jenis, eager loading tanpa N+1 (assert jumlah query), dirty tracking & casts, soft deletes & scopes, observers membatalkan, migrasi up/down/fresh/status, SQLite table-rebuild (semua operasi alter), factory relasi.

### 7.6 Auth, Authorization & Kriptografi

#### 7.6.1 `Hash` & `Crypt`

```dart
abstract final class Hash {
  static Future<String> make(String plain, {HashDriver? driver});     // compute pool
  static Future<bool> check(String plain, String hashed);             // deteksi driver dari prefiks PHC/$2y$
  static bool needsRehash(String hashed);                             // driver/biaya berbeda dari config
  static HashInfo info(String hashed);
}
abstract final class Crypt {
  static String encrypt(Object? value);          // JSON + AES-256-GCM, output base64 payload {iv,value,tag} (+ mac bila mode CBC kompat Laravel)
  static T decrypt<T>(String payload);           // MAC/tag gagal → DecryptException; coba APP_PREVIOUS_KEYS
  static String encryptString(String v); static String decryptString(String p);
}
```

- Argon2id parameter default diuji oleh `dartisan hash:benchmark` (target ±100 ms di mesin produksi, saran Laravel/OWASP).
- `APP_KEY` format `base64:...` 32 byte; `key:generate` dan `key:rotate` (menambahkan kunci lama ke `APP_PREVIOUS_KEYS`, paritas Laravel 11).
- Mode `Crypt.laravelCompatible` (AES-256-CBC + HMAC-SHA256, JSON `{iv,value,mac,tag}`) untuk koeksistensi (4.4).

#### 7.6.2 Guards, Providers & Token

```dart
abstract interface class Authenticatable {
  Object get authIdentifier; String get authIdentifierName; String? get authPassword; String? get rememberToken;
}
abstract interface class UserProvider<T extends Authenticatable> {
  Future<T?> retrieveById(Object id); Future<T?> retrieveByCredentials(Map<String, Object?> credentials);
  Future<bool> validateCredentials(T user, Map<String, Object?> credentials);
  Future<T?> retrieveByToken(Object id, String token); Future<void> updateRememberToken(T user, String token);
}
abstract interface class Guard<T extends Authenticatable> {
  String get name;
  Future<T?> user(); Future<Object?> id(); Future<bool> check(); Future<bool> guest();
  Future<bool> validate(Map<String, Object?> credentials);
  void setUser(T user);                                  // test & middleware
}
abstract interface class StatefulGuard<T extends Authenticatable> implements Guard<T> {
  Future<bool> attempt(Map<String, Object?> credentials, {bool remember = false});
  Future<void> login(T user, {bool remember = false}); Future<void> logout();
}
```

- Guard tier-1: **`TokenGuard` (Sanctum-style)** — header `Authorization: Bearer id|secret`, tabel `personal_access_tokens` identik Sanctum (`tokenable_type`, `tokenable_id`, `name`, `token` sha256, `abilities` JSON, `last_used_at`, `expires_at`), `Auth.issueToken(user, name, abilities: ['posts:read'], expiresAt)`, `tokenCan`, `revokeCurrentToken`, `revokeAll`, `sanctum:prune-expired`; `last_used_at` ditulis maksimal sekali per menit per token (hindari write per request).
- **`JwtGuard`** — HS256 (HMAC `APP_KEY` atau `JWT_SECRET`) + EdDSA (Ed25519 via `cryptography`), klaim `iss, sub, aud, exp, nbf, iat, jti`, leeway 30 s, `kid` untuk rotasi kunci, refresh token opsional (opaque, disimpan hash di DB), denylist `jti` via cache bila `jwt.blacklistEnabled`.
- **`SessionGuard`** (T2) — cookie sesi terenkripsi + `remember_token` + CSRF; mendukung SPA cookie-auth ala Sanctum (`EnsureFrontendRequestsAreStateful`).
- `AuthManager`: multi-guard, `Auth.guard('jwt')`, `shouldUse`, `viaRequest('custom', (req) async => ...)` untuk guard closure; user di-cache per request di `Scope`.
- `AuthenticateMiddleware('auth:token,jwt')` mencoba guard berurutan (paritas) → `AuthenticationException` → 401 JSON `{"message":"Unauthenticated."}`.
- Fitur pendukung: `Auth.once(credentials)`, `Auth.onceUsingId`, login throttling via named limiter `login` (kunci email+IP), email verification & password reset (tabel `password_reset_tokens`, hash token, kedaluwarsa 60 menit) — T2 untuk alur lengkap; token/tabel kompatibel Laravel.

#### 7.6.3 Authorization: `Gate` & `Policy`

```dart
typedef Ability = FutureOr<Object> Function(Authenticatable? user, List<Object?> args); // mengembalikan bool atau AuthResponse

abstract class Policy<T extends Object> {
  FutureOr<Object?> before(Authenticatable? user, String ability) => null;   // true/false/null
  FutureOr<Object> viewAny(Authenticatable? user) => false;  view(user, T model); create(user); update(user, T model); delete(user, T model); restore(...); forceDelete(...);
  Map<String, FutureOr<Object> Function(Authenticatable? user, List<Object?> args)> get extra => const {};
}

final class Gate {
  void define(String ability, Ability callback);
  void policy<T extends Object>(Policy<T> policy);              // kunci: Type T (runtime), dari bootstrap/policies.dart
  void before(Ability hook); void after(...);
  Future<bool> allows(String ability, [List<Object?> args]); denies; check; any; none;
  Future<void> authorize(String ability, [List<Object?> args]);  // throw AuthorizationException (403)
  Future<AuthResponse> inspect(String ability, [List<Object?> args]);
  Gate forUser(Authenticatable? user);
}
```

- Dispatch policy: `Gate.authorize('update', [post])` → cari policy terdaftar untuk `post.runtimeType` (naik ke supertipe yang terdaftar lewat `isA` check di registry, bukan refleksi) → panggil `update`. Kemampuan non-standar lewat `extra` map.
- Middleware `can:update,post` mengambil model dari route binding bernama `post`; `req.authorize('update', post)`; `FormRequest.authorize` menerima `req.user()`.
- `AuthResponse` membawa `message` dan `code` untuk 403 yang informatif; `Gate.after` untuk audit log.

#### 7.6.4 Session & CSRF (T2, dirancang sekarang agar kontrak stabil)

`SessionStore` (`memory[isolate]`, `file`, `database(sessions)`, `redis`), `Session` API (`get/put/pull/flash/regenerate/invalidate/token`), cookie `daravel_session` terenkripsi + `HttpOnly; SameSite=Lax; Secure` (otomatis saat HTTPS), `VerifyCsrfToken` (`X-CSRF-TOKEN`/`X-XSRF-TOKEN`/`_token`, `except`), rotasi id saat login (fixation), `session.lifetime`, GC probabilistik (lottery) → di-schedule, bukan per request.

#### 7.6.5 Kebijakan keamanan transversal (ringkas; rinci di Bagian 9)

Semua perbandingan rahasia memakai `constantTimeEquals`; semua acak memakai `Random.secure()`; token dikirim ke log **tidak pernah** (`Log` redaksi otomatis untuk kunci `password, token, authorization, cookie, secret`); header `Server` tidak mengungkap versi; CORS default **tanpa** `*` bila `supportsCredentials`.

### 7.7 Cache, Rate Limiter, Locks & Coordinator

```dart
abstract interface class CacheStore {
  StateScope get scope;                           // isolate | process | cluster
  Future<T?> get<T>(String key); Future<Map<String, Object?>> many(List<String> keys);
  Future<void> put(String key, Object? value, {Duration? ttl}); putMany; add (hanya jika belum ada — atomik);
  Future<int> increment(String key, [int by = 1]); decrement;
  Future<void> forever(String key, Object? value); Future<bool> forget(String key); Future<void> flush();
  Future<Lock> lock(String name, {Duration ttl = const Duration(seconds: 10), String? owner});
  String get prefix;
}
```

- Store tier-1: `MemoryStore` (isolate; LRU dengan `maxEntries`/`maxBytes` — **wajib terbatas**, mencegah kebocoran memori ala Octane), `ProcessStore` (coordinator-backed; konsisten lintas isolate, data di main isolate), `FileStore` (dir `storage/cache`, atomik rename), `DatabaseStore` (tabel `cache`, `cache_locks` identik Laravel). Tier-2: `RedisStore` (+ tags).
- `Cache.remember<T>(key, ttl, fn)`, `rememberForever`, `pull`, `flexible(key, [fresh, stale], fn)` (SWR, paritas Laravel 11), `Cache.store('file')`, `Cache.tags([...])` (T2), serialisasi JSON (nilai harus JSON-serializable; `Model` disimpan sebagai atribut + tipe terdaftar).
- **Stampede protection**: `remember` memakai lock per kunci (`process` scope) sehingga hanya satu isolate menghitung ulang; lainnya menunggu atau memakai nilai basi (`flexible`).
- `Lock`: `get()`, `block(Duration)`, `release()`, `forceRelease()`, `owner`; semantik **fail-closed** (gagal berkomunikasi dengan coordinator → `LockTimeoutException`).
- **`RateLimiter`**: algoritma **sliding window log** (default, akurat) dan **token bucket** (opsional, burst-friendly); `RateLimiter.for('api', (req) => Limit.perMinute(60).by(req.user()?.id ?? req.ip))`, `Limit.perSecond/perMinute/perHour/perDay`, `.response((req, headers) => ...)`, `.by(key)`, `.none()`, multi-limit per rute; header `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `Retry-After`, `X-RateLimit-Reset`; store `process` default pada multi-isolate; `cluster` via Redis Lua script atomik (T2).
- **Coordinator isolate** (ADR-003): registry service (`rateLimiter`, `locks`, `processCache`, `scheduleMutex`, `metrics`), protokol `sealed class CoordinatorMessage` → `CoordinatorReply`, satu `ReceivePort` per worker untuk balasan, `correlationId` ULID, timeout per service, backpressure (antrian > 10.000 pesan → fail-open/closed sesuai kebijakan + metrik). State coordinator dapat di-*snapshot* untuk debugging (`dartisan coordinator:stats`). Pada `isolates=1`, semua service `process` berjalan in-process tanpa pesan.

### 7.8 Events & Listeners

```dart
final class EventDispatcher {
  void listen<E extends Object>(FutureOr<void> Function(E event) listener, {int priority = 0, bool once = false});
  void subscribe(EventSubscriber subscriber);
  Future<void> dispatch<E extends Object>(E event);             // await semua listener sync (urut prioritas)
  void dispatchAfterCommit<E extends Object>(E event);          // ditunda hingga transaksi Zone aktif commit (paritas ShouldDispatchAfterCommit)
  void queue<E extends Object>(E event);                        // listener ShouldQueue → job
  bool hasListeners<E>(); void forget<E>(); 
  Stream<E> on<E extends Object>();                             // integrasi Stream Dart
}
```

- Listener yang `ShouldQueue` dideklarasikan sebagai `QueuedListener<E>` dengan `toJson/fromJson` event (terdaftar di `bootstrap/listeners.dart`); event tanpa serializer tidak boleh di-queue (error saat boot, bukan runtime).
- Event framework bawaan: `RequestHandled`, `QueryExecuted`, `TransactionCommitted/RolledBack`, `JobProcessing/Processed/Failed`, `CacheHit/Missed`, `Authenticated`, `Login/Logout/Lockout`, model events, `ScheduledTaskStarting/Finished`.
- `Event.fake()` di test: tangkap & assert `dispatched<E>(matcher)`, `notDispatched<E>()`, `dispatchedTimes`.

### 7.9 Queue, Jobs & Scheduler

#### 7.9.1 Kontrak Job

```dart
abstract class Job {
  const Job();
  String get jobName;                                   // kunci registry (stabil terhadap rename)
  Map<String, Object?> toJson();                        // payload JSON (tanpa objek Dart; model → key, dimuat ulang saat handle)
  Future<void> handle(JobContext ctx);
  int get tries => 1; Duration get timeout => const Duration(minutes: 1); List<Duration> get backoff => const [];
  Duration? get retryUntil => null; String? get queue => null; String? get connection => null;
  int get maxExceptions => tries; bool get failOnTimeout => false;
  List<JobMiddleware> get middleware => const [];        // RateLimited, WithoutOverlapping, ThrottlesExceptions
  Future<void> failed(Object error, StackTrace st) async {}
  String? get uniqueId => null; Duration get uniqueFor => Duration.zero;   // ShouldBeUnique
}
final class JobRegistry { void register<J extends Job>(String name, J Function(Map<String, Object?> json) factory); }
```

- `SerializesModels` paritas: helper `ModelRef<T>(id)` di payload → `await ref.resolve()` saat `handle` (model dimuat segar; bila hilang → `ModelNotFoundException` dan job gagal tanpa retry, paritas Laravel).
- Dispatch: `Queue.dispatch(job)`, `.onQueue('emails')`, `.delay(Duration)`, `.afterCommit()`, `Queue.later`, `Queue.bulk`, `Queue.chain([...])` (T2), `Bus.batch` (T3). Di dalam transaksi Zone, default `afterCommit` (konfigurasi `queue.afterCommit = true` disarankan; paritas opsi Laravel).
- Driver tier-1: `sync` (langsung, untuk dev/test), `database` (tabel `jobs`, `failed_jobs`, `job_batches` skema identik Laravel; *claim* dengan `UPDATE … WHERE id = (SELECT … FOR UPDATE SKIP LOCKED)` di Postgres, `BEGIN IMMEDIATE` di SQLite), `memory[process]` (coordinator, untuk `--embed-queue` tanpa DB). Tier-2: `redis` (list + zset delayed + reserved, Lua atomik, kompatibel struktur kunci Laravel sedapat mungkin).
- Worker: `dartisan queue:work [--queue=high,default] [--tries=3] [--backoff=10,30,60] [--timeout=60] [--sleep=3] [--max-jobs=1000] [--max-time=3600] [--memory=256] [--stop-when-empty]`; setiap job berjalan di **Zone scope `job`** (container scope, request-id = job id, log context); timeout job dijalankan dengan `Future.timeout` + flag pembatalan kooperatif (`ctx.cancelled`), karena Dart tidak bisa membunuh Future — **job yang memblokir CPU** harus dijalankan via `Isolate.run` oleh job itu sendiri (didokumentasikan). `queue:restart` lewat sinyal cache (`process`/`cluster`), `queue:retry [id|all]`, `queue:failed`, `queue:flush`, `queue:prune-failed`, `queue:monitor` (ambang panjang antrean → event).
- Worker juga bisa **tertanam** di proses HTTP (`--embed-queue=2`) sebagai isolate terpisah — cocok untuk deployment single-binary kecil.

#### 7.9.2 Scheduler

```dart
schedule.job(PruneTokens()).daily().at('03:00');
schedule.command('sanctum:prune-expired', ['--hours=24']).hourly();
schedule.call(() async {...}).everyFiveMinutes().withoutOverlapping(expiresAfter: Duration(minutes: 30)).onOneServer().runInBackground();
schedule.exec('pg_dump ...').weeklyOn(DateTime.sunday, '02:00').timezone('Asia/Makassar').environments(['production']).emailOutputOnFailure(...) /* T2 */;
```

- Parser cron 5-field + alias (`@hourly`), `timezone` per task (data zona waktu: `package:timezone` opsional; default UTC + offset tetap dari config — dicatat sebagai keterbatasan tier-1), `when/skip`, `between/unlessBetween`, `onSuccess/onFailure`, `before/after`, `pingBefore/thenPing` (T2).
- `schedule:run` (dipanggil cron OS tiap menit) dan `schedule:work` (loop internal, atau `--embed-scheduler`); `withoutOverlapping` dan `onOneServer` memakai `Lock` (`process` dalam satu proses, `cluster` untuk multi-server — wajib `cluster` store bila `onOneServer`, divalidasi saat boot).
- `schedule:list`, `schedule:test --name=...`.

Matriks test: serialisasi/deserialisasi job (round-trip JSON), retry/backoff/`retryUntil`, `failed_jobs` dicatat dengan trace, unique job, `afterCommit` dengan rollback (job tidak terkirim), worker `max-jobs/max-time`, claim konkuren 4 worker × 1.000 job tanpa duplikasi (Postgres), cron parser property test vs implementasi referensi, `withoutOverlapping` dengan 2 scheduler.

### 7.10 Storage, Mail, Logging, Observability, API Resources, Localization, Realtime, OpenAPI

#### 7.10.1 Storage

`Disk` interface (`put/putStream/get/getStream/exists/delete/copy/move/size/lastModified/url/temporaryUrl/files/directories/makeDirectory/deleteDirectory`), driver `local` (root `storage/app`, path traversal **ditolak** lewat normalisasi + prefix check, `visibility` memetakan ke chmod di POSIX), `public` (symlink `public/storage` via `storage:link`), `memory` (test), `s3` (T2 via `minio`, SigV4, presigned URL). `UploadedFile.store(path, disk)`, `storeAs`, `hashName`, validasi MIME berdasar *magic bytes* (bukan ekstensi) untuk `image/mimes`. `Storage.fake('avatars')` di test + `assertExists`.

#### 7.10.2 Mail (T2, kontrak dirancang sekarang)

`Mailable` (`envelope()`, `content()` → template mustache/HTML string builder, `attachments()`), `Mail.to(user).send(WelcomeMail(user))`, `queue()`, driver `smtp` (`mailer` 7.x), `log`, `array` (test), `Mail.fake()` + `assertSent<WelcomeMail>((m) => m.hasTo(email))`. `Notification` (T3) dengan channel `mail/database/broadcast`.

#### 7.10.3 Logging

`Log` facade dengan channel (`stack`, `console` ANSI untuk dev, `json` stdout untuk produksi/containers, `file` rotasi harian + retensi, `syslog` T2), level RFC 5424, `Log.withContext({...})` per Zone (request id, user id, route otomatis), `Log.channel('audit')`, `Log.shareContext`, redaksi otomatis kunci sensitif, stack trace terformat, *sampling* untuk level debug di produksi, `Log.spy()` di test (`assertLogged(level, matcher)`). Tulis ke stdout **non-blocking** (buffer + flush berkala; backpressure drop dengan counter `logs_dropped_total`).

#### 7.10.4 Observability

- **Metrics**: registry Prometheus text format di `/metrics` (opsional, bisa dipindah ke port admin terpisah `--admin-port`), counter/gauge/histogram bawaan: `http_requests_total{method,route,status}`, `http_request_duration_seconds` (histogram per rute, **label rute bukan path** untuk cardinality), `db_query_duration_seconds`, `db_pool_in_use`, `queue_jobs_total{status}`, `cache_ops_total{result}`, `isolate_event_loop_lag_seconds` (diukur dengan timer 1 s), `process_memory_bytes`. Agregasi lintas isolate oleh coordinator (ADR-003).
- **Tracing**: integrasi `opentelemetry` 0.18.x (T2) dengan span otomatis per request, query, job, HTTP client; propagasi `traceparent`.
- **Health**: `/up` (liveness: 200 selama tidak draining) dan `/up/ready` (readiness: cek DB ping, cache, queue) dengan timeout 2 s; format JSON `{status, checks:{db:{ok,ms}}}`; dapat ditambah `HealthCheck` kustom.
- **Request log** terstruktur (status, durasi, bytes, user id, route) — Pulse/Telescope-lite via `dartisan serve --inspect` yang menampilkan request terakhir di terminal (T2: UI web lokal).

#### 7.10.5 API Resources

```dart
abstract class Resource<T extends Object> implements Responsable {
  const Resource(this.resource);
  final T resource;
  Map<String, Object?> toArray(Request req);
  Map<String, Object?> with_(Request req) => const {};          // meta tambahan
  Object? whenLoaded<M extends Model<M>>(M model, String relation, Object? Function() value);
  Object? when(bool condition, Object? Function() value, [Object? Function()? otherwise]);
  Map<String, Object?> mergeWhen(bool condition, Map<String, Object?> Function() values);
  static ResourceCollection<T> collection<T extends Object>(Iterable<T> items, Resource<T> Function(T) factory);
}
```

Perilaku paritas: pembungkus `data` secara default (`Resource.withoutWrapping()` global), koleksi dari paginator menghasilkan `data + links + meta` identik Laravel, `whenLoaded` mencegah N+1 diam-diam, `additional({...})`, status 201 via `.response().withStatus(201)` atau `Response.created(resource)`. Resource menyumbang **schema OpenAPI** lewat `schema()` opsional (atau inferensi dari contoh di test).

#### 7.10.6 Localization (T2)

`Lang.get('validation.required', {'attribute': 'email'})` / helper `trans()`; sumber `lang/<locale>/<file>.dart` (map Dart, bukan JSON, agar ikut AOT & typecheck) + `lang/<locale>.json` opsional (dibaca saat boot); pluralisasi `{0} none|{1} one|[2,*] many`; fallback locale; `SetLocale` middleware dari `Accept-Language`/query/user; pesan validasi `en` dan `id` bawaan.

#### 7.10.7 Realtime: SSE & WebSocket (T2, kontrak sekarang)

- SSE: `Response.eventStream(stream)` dengan `id/event/retry`, keep-alive comment tiap 15 s, dukungan `Last-Event-ID`.
- WebSocket: `router.ws('/ws/chat/{room}', ChatSocket.new)` → `WebSocketHandler` (`onOpen/onMessage/onClose/onError`), autentikasi via middleware rute biasa sebelum upgrade (`dart:io` `WebSocketTransformer.upgrade`), **channel registry** lintas isolate via coordinator (`Broadcast.to('room.1').send(...)`) dan via Redis pub/sub untuk multi-server (T2). Batas ukuran frame, ping/pong, idle timeout. Kompatibilitas protokol **Pusher** (dipakai Laravel Echo/Reverb) sebagai target T3 agar klien Echo yang ada dapat dipakai.

#### 7.10.8 OpenAPI dari Introspeksi

`dartisan openapi:generate [--out=openapi.json] [--format=yaml]` membangun dokumen OpenAPI 3.1 dari: `router.routes` (path, method, param + constraint → `schema`), metadata `RouteEntry` (`summary/tags/responses`), `FormRequest` terdaftar lewat `validates<T>()` (aturan `Rule.schemaHint` → properti `required/type/format/min/max/enum/pattern`), `Resource.schema()`, guard rute (`securitySchemes` bearer), dan paginator. Tidak ada refleksi: semua dari objek yang memang ada saat boot. Validasi dokumen hasil dengan test snapshot; `openapi:serve` menyajikan Swagger UI/Scalar statis (aset tertanam) di dev.

### 7.11 Testing Toolkit (`daravel_test`)

```dart
final class TestClient {
  TestClient(Application app, {Map<String, String> defaultHeaders = const {}});
  TestResponse get(String uri, {Map<String,String>? headers});
  TestResponse post(String uri, {Object? json, Map<String,String>? form, List<TestFile>? files, Map<String,String>? headers});
  put/patch/delete/options/head; TestResponse json(String method, String uri, Object? body);
  TestClient actingAs(Authenticatable user, {String? guard}); withToken(String token); withHeaders(Map); withCookie(String, String); withSession(Map) /* T2 */;
  TestClient withoutMiddleware<T extends Middleware>(); withoutExceptionHandling(); 
}
final class TestResponse {
  int get status; Headers get headers; String get body; Object? get json; Map<String, Object?> get jsonMap;
  TestResponse assertStatus(int s); assertOk(); assertCreated(); assertNoContent(); assertNotFound(); assertUnauthorized(); assertForbidden(); assertUnprocessable(); assertRedirect([String? to]);
  TestResponse assertJson(Map<String, Object?> subset); assertExactJson(Map); assertJsonPath(String path, Object? expected); assertJsonCount(int n, [String? path]); assertJsonStructure(Object structure); assertJsonFragment(Map); assertJsonMissing(Map);
  TestResponse assertJsonValidationErrors(Object keysOrMap); assertJsonMissingValidationErrors([List<String>? keys]); assertValid(); assertInvalid(Map<String,String> errors);
  TestResponse assertHeader(String name, [String? value]); assertHeaderMissing(String); assertCookie(String name); assertSee(String text); assertDontSee(String);
  TestResponse dump(); dd();
}
```

- **`RefreshDatabase`** (mixin/helper `setUpDatabase()`): migrasi sekali per isolate test (`:memory:` SQLite per isolate `dart test` → paralelisme gratis), setiap test berjalan di **transaksi yang di-rollback** (Postgres: `BEGIN` + savepoint untuk transaksi aplikasi; Zone memastikan semua query ikut). `DatabaseMigrations` (migrate fresh per test) untuk kasus DDL. `useTestDatabase('postgres')` untuk menjalankan suite yang sama ke Postgres di CI.
- Assertion DB: `assertDatabaseHas('users', {...})`, `assertDatabaseMissing`, `assertDatabaseCount`, `assertSoftDeleted`, `assertModelExists(user)`, `assertModelMissing`.
- Fakes: `Event.fake()`, `Queue.fake()` (`assertPushed<J>((j) => ...)`, `assertPushedOn`, `assertNothingPushed`), `Mail.fake()`, `Storage.fake()`, `Http.fake({...})` (T2), `Cache` memory, `Clock.fake(DateTime)`/`travel(Duration)`/`freeze()` (semua `now()` framework lewat `package:clock`), `Hash.fast()` (parameter biaya minimal di test), `Log.spy()`.
- Factories (7.5.6) & seeders di test; `Auth.actingAs`.
- Test arsitektur bawaan untuk aplikasi pengguna: `daravel_test/architecture.dart` menyediakan `expectNoMutableStatics('lib/app')`, `expectRegistryComplete()` — dijalankan `dartisan test`.
- Konvensi folder starter: `test/unit`, `test/feature`, `test/conformance` (diwarisi dari framework untuk memverifikasi app tidak melanggar kontrak format JSON).

### 7.12 Support: Collections, Str, Helpers

- `Collection<T>` ala Laravel di atas `Iterable`/`List` Dart (`map/filter/where/pluck/groupBy/keyBy/sortBy/chunk/sum/avg/first/firstWhere/unique/flatten/zip/partition/each/pipe/tap/toJson`), lazy via Dart `Iterable`; **tidak** menggantikan `package:collection`, hanya pelengkap ergonomis. Extension pada `Iterable<T>` (`iterable.pluck('name')`) untuk nol konversi.
- `Str` (`slug, snake, camel, studly, kebab, title, limit, random(secure), uuid, ulid, plural/singular (aturan EN), mask, contains, startsWith, padBoth, squish, wordCount, markdown (T3)`), `Number` (format, fileSize, currency via `intl` T2).
- Helper top-level: `env()`, `config()`, `app<T>()`, `abort(status, [message])`, `abortIf/abortUnless`, `response()`, `redirect()`, `route()`, `url()`, `now()`, `today()`, `defer()`, `retry(times, fn, {delay})`, `rescue(fn, {fallback, report})`, `once(fn)` (memo per scope), `tap`, `value`, `blank/filled`, `dd/dump` (ke stdout dev; nonaktif produksi), `base64url`, `str()`.
- `Carbon`-like: tidak mereinvent `DateTime`; sediakan extension `DateTime` (`addDays`, `startOfDay`, `diffForHumans` (`id`/`en`), `toDateString`, `isPast`, `toIsoUtc`) dan `Clock` injectable.

---

## 8. `dartisan` CLI & Developer Experience

### 8.1 Arsitektur CLI

- Satu executable `dartisan` dengan dua mode: **global** (`dart pub global activate dartisan_cli`; untuk `new`, `doctor`, `about`) dan **project-bound** (`dart run dartisan` atau `bin/dartisan.dart` yang mem-boot aplikasi pengguna untuk `migrate`, `route:list`, `queue:work`, command kustom). Mode global mendeteksi proyek Daravel (`pubspec.yaml` dengan dependensi `daravel`) dan **mendelegasikan** ke executable proyek agar versi framework proyek yang dipakai (seperti `composer` vs `artisan`).
- Command kustom pengguna: kelas `Command` (`signature`, `description`, `handle(CommandContext ctx)`, `ArgParser` builder bertipe), terdaftar di `bootstrap/commands.dart`; `make:command`.
- Output via `mason_logger` (spinner, tabel, prompt, progress) dengan mode `--no-interaction`, `--quiet`, `--json` untuk tooling/CI; kode keluar konsisten (0 ok, 1 error, 2 usage, 130 interrupted).

### 8.2 Katalog Perintah

| Kelompok | Perintah | Catatan |
| :-- | :-- | :-- |
| Proyek | `new <name> [--template=api\|minimal] [--db=sqlite\|postgres] [--git] [--docker]`, `about`, `doctor`, `env:check`, `env:encrypt/decrypt`, `key:generate [--show]`, `key:rotate`, `stub:publish`, `optimize` (no-op dengan pesan edukatif), `script <file.dart>` (jalankan skrip di konteks aplikasi, pengganti `tinker`) | `doctor`: versi Dart, native lib sqlite3, port, `.env` vs example, pool math, `APP_DEBUG` di prod |
| Serve/Build | `serve [--host] [--port] [--isolates] [--watch] [--restart-only] [--inspect] [--admin-port]`, `build [--output] [--target=exe\|aot-snapshot] [--define KEY=VAL] [--docker]`, `test [--coverage] [--conformance]` | `build --docker` menulis Dockerfile multi-stage + menjalankan `docker build` opsional |
| Routing | `route:list [--path=] [--method=] [--name=] [--middleware=] [--json] [--reverse]`, `route:check` (duplikasi nama, param tak terpakai) | — |
| Database | `migrate [--step] [--pretend] [--force] [--seed] [--schema]`, `migrate:rollback [--step=] [--batch=]`, `migrate:reset`, `migrate:refresh`, `migrate:fresh [--seed]`, `migrate:status`, `migrate:install`, `db:seed [--class=]`, `db:wipe`, `db:show`, `db:table <name>`, `db:monitor`, `schema:dump [--prune]`, `model:sync [Model] [--dry-run]`, `model:show <Model>` | `model:sync` memperbarui region accessor dari skema DB |
| Generator | `make:controller <Name> [--api] [--resource] [--invokable] [--model=]`, `make:model <Name> [-m] [-c] [-f] [-s] [-p] [--all]`, `make:migration <name> [--create=] [--table=]`, `make:seeder`, `make:factory [--model=]`, `make:request`, `make:middleware`, `make:policy [--model=]`, `make:job [--sync]`, `make:listener [--event=]`, `make:event`, `make:observer [--model=]`, `make:command`, `make:provider`, `make:resource [--collection]`, `make:rule`, `make:mail` (T2), `make:test [--unit]`, `make:cast`, `make:scope`, `make:channel` (T2) | Semua memperbarui registry (ADR-002), idempoten, `--force` untuk timpa |
| Auth | `sanctum:prune-expired [--hours=]`, `auth:clear-resets`, `jwt:secret`, `hash:benchmark` | — |
| Queue/Schedule | `queue:work`, `queue:listen` (restart otomatis saat kode berubah, dev), `queue:restart`, `queue:retry`, `queue:failed`, `queue:forget`, `queue:flush`, `queue:prune-failed`, `queue:monitor`, `queue:clear`, `schedule:run`, `schedule:work`, `schedule:list`, `schedule:test` | — |
| Cache/Storage | `cache:clear [--store=]`, `cache:forget <key>`, `cache:prune-stale-tags` (T2), `storage:link`, `storage:unlink` | — |
| Dokumentasi | `openapi:generate`, `openapi:serve`, `client:generate --lang=dart` (T2) | — |
| Registry | `registry:check`, `registry:sync` | Gagal di CI bila ada kelas belum terdaftar |
| Lain | `coordinator:stats`, `config:show <domain>`, `lang:publish` (T2), `vendor:publish --provider=` (aset paket) | — |

### 8.3 Scaffold-Time Generation: Desain Generator

- **Stub** = template teks dengan placeholder `{{ class }}`, `{{ table }}`, `{{ namespace }}` + blok kondisional sederhana; disimpan di `dartisan_cli/stubs/`, dapat dipublikasikan ke `stubs/` proyek (prioritas proyek > bawaan).
- **Registry patcher**: parser berbasis marker, bukan AST penuh: temukan `// <dartisan:imports>` dan `// <dartisan:entries>` di file registry, sisipkan baris terurut alfabetis, hindari duplikasi, jalankan `dart format` pada file yang disentuh. Bila marker hilang (file diedit manual), CLI menolak dengan instruksi memulihkan marker (atau `--no-registry`).
- **Idempoten & aman**: tidak pernah menimpa file tanpa `--force`; menampilkan diff ringkas; `--dry-run`.
- **Penamaan**: `make:model Post` → `lib/app/models/post.dart` (`class Post`), tabel `posts` (pluralisasi EN bawaan, override `--table`), migrasi `database/migrations/2026_10_23_143000_create_posts_table.dart` + kelas `CreatePostsTable` + entri registry.
- **`model:sync`**: introspeksi skema (`Schema.getColumns`) → tipe Dart (`int, double, String, bool, DateTime, Map, List, Uint8List`) → tulis ulang **hanya** region `<dartisan:accessors>`; kolom yang dihapus dari DB dihapus dari region dengan peringatan; akses kustom developer di luar region tidak disentuh.

### 8.4 Hot Reload Dev Server (rinci ADR-010)

1. `dartisan serve --watch` menjalankan `dart run --enable-vm-service=0 --disable-service-auth-codes bin/server.dart` (hanya bind `127.0.0.1` untuk VM service), menangkap URI service dari stdout.
2. `watcher` 1.2.x memantau `lib/`, `bin/`, `bootstrap/`, `config/`, `database/`, `routes/`, `.env` dengan debounce 300 ms; `.env` → selalu restart (env dibaca saat boot).
3. Pada perubahan: `vm_service.reloadSources(isolateId)` untuk **semua** isolate aplikasi (dev default satu isolate); sukses → kirim `SIGUSR`-like pesan lewat VM service extension `ext.daravel.reloaded` → framework menjalankan `onHotReload` hooks (rebuild router dari fungsi rute, flush cache volatile, re-run `boot()` provider yang ditandai `reloadable`).
4. Gagal (error kompilasi) → tampilkan error ringkas dengan path:baris; tunggu perubahan berikutnya; gagal (tidak didukung) → restart otomatis penuh dengan pesan alasan.
5. Metrik DX yang diukur di CI: waktu reload median pada starter app (target < 500 ms), waktu restart (< 3 s).

### 8.5 `dartisan new`: Template Proyek

Template `api` (default) berisi: `bootstrap/` (app, providers, registries), `config/`, `routes/api.dart`, `app/http/controllers/auth_controller.dart`, `app/models/user.dart`, migrasi `users`, `personal_access_tokens`, `cache`, `cache_locks`, `jobs`, `failed_jobs`, `sessions`(T2), seeder + factory `User`, `test/feature/auth_flow_test.dart`, `.env.example`, `analysis_options.yaml` (strict + `daravel_lints`), `Dockerfile` multi-stage (builder `dart:stable` → runtime `debian:bookworm-slim` + `libsqlite3-0` bila SQLite, atau `gcr.io/distroless/cc` untuk Postgres-only), `docker-compose.yml` (postgres + app), `.github/workflows/ci.yml` (analyze, test, compile exe, conformance), `README.md`.

### 8.6 Deployment Guidance (bagian DX)

- **Single binary**: `dartisan build` → `build/server` (±10–20 MB; sudah termasuk runtime Dart; membutuhkan glibc; tidak statis sepenuhnya). Startup < 100 ms → cocok untuk Cloud Run/Fly/Lambda custom runtime dengan `--isolates` sesuai vCPU.
- **Topologi A** (direkomendasikan): reverse proxy (Caddy/nginx) → TLS, HTTP/2/3, kompresi br → Daravel HTTP/1.1 `127.0.0.1:8000`; `TrustProxies` diset ke proxy itu. **Topologi B**: eksposur langsung dengan `SecurityContext` TLS (sertifikat dari file/ACME eksternal).
- Proses pekerja terpisah untuk `queue:work`/`schedule:work` di produksi (supervisor: systemd/k8s), atau `--embed-*` untuk deployment kecil.
- Env di container: variabel OS > `.env`; `APP_KEY` dari secret manager; `dartisan doctor --production` sebagai pre-flight check di entrypoint.

---

## 9. Kerangka Keamanan

### 9.1 Model Ancaman (ringkas, STRIDE)

| Ancaman | Vektor | Kontrol bawaan | Konfigurasi/Dokumentasi |
| :-- | :-- | :-- | :-- |
| Spoofing | `X-Forwarded-*` palsu, token tebakan, JWT `alg=none` | TrustProxies kosong by default; token 40 byte `Random.secure`; JWT menolak `none` & memverifikasi `alg` terhadap kunci yang dikonfigurasi | `trustProxies(cidrs)` eksplisit |
| Tampering | Mass assignment, cookie, signed URL | `fillable/guarded`; cookie terenkripsi + MAC; signature HMAC + kedaluwarsa | `preventSilentlyDiscarding` |
| Repudiation | Tidak ada jejak | Request id, audit log channel, `Gate.after` | `Log.channel('audit')` |
| Information disclosure | Stack trace, `hidden` lupa, header `Server`, error DB | `APP_DEBUG=false` di prod (validasi boot), `hidden` default `password`, header minimal, pesan DB disanitasi | — |
| DoS | Body besar, slowloris, regex (ReDoS), JSON dalam, N+1, hash cost | Body limits, timeouts, `RegExp` linear-time hanya di rule bawaan (uji ReDoS), kedalaman JSON, `preventLazyLoading` di dev, hashing di compute pool dengan antrean terbatas | Rate limiter named, `maxConnections` |
| Elevation of privilege | Lupa `auth`/`can`, IDOR | `route:check --require-auth=/api/*` (lint rute tanpa middleware auth), `scopeBindings`, Policy default `false` | CI rule |
| Injection | SQL, header CRLF, path traversal | Binding wajib + identifier whitelist char; header value disanitasi (`\r\n` ditolak); storage path normalisasi | `daravel_lints` interpolasi SQL |
| Supply chain | Dependensi | Kebijakan "pure Dart first", `dart pub outdated` di CI, pin versi, SBOM (`dart pub deps --json`) | Dependabot/renovate |

### 9.2 Default yang Aman (checklist "secure by default")

1. `APP_ENV=production` + `APP_DEBUG=true` → boot gagal kecuali `--allow-debug-in-production` (eksplisit, tercatat).
2. `APP_KEY` wajib 32 byte; `Crypt`/`Session`/`signed URL` menolak kunci lemah.
3. CORS: tidak ada origin yang diizinkan sampai dikonfigurasi; `*` dilarang bersama credentials.
4. Cookie: `HttpOnly`, `SameSite=Lax`, `Secure` otomatis di HTTPS, nama berprefix `__Host-` opsional.
5. Header keamanan API: `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options: DENY` (bila HTML), `Strict-Transport-Security` saat HTTPS, `Cache-Control: no-store` untuk respons terautentikasi (opsional).
6. Rate limit bawaan untuk `login`/`register`/`password.reset` di starter (`5/menit per email+IP`).
7. Log tidak pernah berisi rahasia (redaksi) dan tidak mencetak body request secara default.
8. Upload: MIME dari magic bytes, nama file di-hash, disimpan di luar web root, ekstensi eksekusi ditolak di disk `public`.
9. Pesan error autentikasi generik ("Invalid credentials."), timing login diseragamkan (hash dummy saat user tidak ditemukan — *user enumeration* mitigasi).
10. `dartisan doctor --production` memeriksa semua poin di atas dan gagal bila ada pelanggaran kritis.

### 9.3 Proses Keamanan

- Test keamanan di suite konformansi: injeksi SQL (payload OWASP), XFF spoofing, body melebihi batas, JWT `alg` manipulasi, token kedaluwarsa, CSRF (T2), path traversal storage, ReDoS pada rule regex bawaan (input adversarial 100 KB harus < 10 ms).
- `SECURITY.md` + proses pelaporan; rilis patch keamanan dengan advisory di pub.dev changelog.
- Fuzzing ringan untuk parser (`.env`, multipart, JSON depth, cron, SQL tokenizer) memakai generator acak di test (property-based, `package:test` + seed).

---

## 10. Performa & Skalabilitas

### 10.1 Prinsip

Dart `dart:io` HttpServer single-isolate sudah mampu puluhan ribu request/detik untuk payload kecil; multi-isolate menskalakan mendekati linier hingga jumlah core untuk beban CPU-ringan. **Angka pasti tidak diklaim di dokumen ini** (P10); harness-lah yang menetapkan baseline per rilis.

### 10.2 Benchmark Harness (`bench/`)

- Alat: `oha` atau `wrk` (HTTP), `pgbench`-style skrip untuk DB; dijalankan di mesin referensi yang dicatat (CPU, RAM, OS, versi Dart) dan di CI nightly (relatif, bukan absolut: deteksi **regresi > 10%**).
- Skenario: (1) `GET /ping` teks (overhead framework murni), (2) `GET /api/users/{id}` JSON + 1 query Postgres, (3) `POST /api/users` validasi + insert + transaksi, (4) `GET /api/posts?with=author,comments` eager loading (N+1 check), (5) throttle aktif (biaya coordinator), (6) login (hash di compute pool), (7) upload 5 MB multipart, (8) SSE 1.000 koneksi idle, (9) hot path `Zone` overhead microbenchmark, (10) startup time binary AOT dan memori RSS saat idle dengan `isolates=1/4/8`.
- Metrik: rps, p50/p95/p99 latency, RSS, CPU per request, koneksi DB puncak, `event_loop_lag`.
- Target relatif internal (bukan janji publik): overhead framework pada skenario (1) ≤ 25% dibanding `dart:io` polos; skenario (5) menambah ≤ 100 µs p50 dibanding tanpa throttle; `isolates=4` memberi ≥ 3× rps skenario (1) dibanding `isolates=1` pada 4+ core.

### 10.3 Teknik yang Dipakai di Hot Path

- Pra-komputasi saat boot: rantai middleware per rute, nama rute → entry, grammar `wrap` cache identifier, pesan validasi default.
- Hindari alokasi: Radix match tanpa alokasi untuk statik; `Headers` lazy; body tidak dibaca kecuali diminta; JSON encode langsung ke `IOSink` dengan `JsonUtf8Encoder` (chunked) untuk payload > 64 KB.
- Pool DB warm-up (`minIdle`) saat boot; prepared statement cache (`postgres` mendukung) dengan batas LRU 256 per koneksi.
- Logging non-blocking; metrik lock-free per isolate dengan agregasi berkala (1 s) ke coordinator.
- Kompresi hanya > 1 KB dan hanya tipe teks/JSON; `ETag` lemah dari hash isi untuk respons kecil.
- Hashing/encode besar di compute pool; antrean compute terbatas (default 64) → 503 cepat bila penuh (dicatat metrik), bukan latensi tak terbatas.

### 10.4 Pengaturan Skala

| Dimensi | Pengaturan | Catatan |
| :-- | :-- | :-- |
| CPU | `--isolates=N` (default = core) | Beban I/O-bound bisa > core; CPU-bound = core |
| DB | `pool.maxTotal` dibagi isolate; PgBouncer disarankan bila > 100 koneksi | `doctor` memperingatkan |
| Memori | `MemoryStore.maxBytes` per isolate; `--isolates` × RSS | RSS per isolate ±30–60 MB tipikal; diukur |
| Horizontal | Stateless HTTP + `cluster` store (Redis/DB) untuk rate limit/lock/session | `onOneServer` wajib `cluster` |
| Latensi ekor | `requestTimeout`, antrean compute terbatas, `preventLazyLoading` | — |

---

## 11. Kualitas, Tata Kelola & Metode Kerja

### 11.1 Analisis Statis

```yaml
# analysis_options.yaml (root workspace)
include: package:lints/recommended.yaml
analyzer:
  language: { strict-casts: true, strict-inference: true, strict-raw-types: true }
  errors: { missing_required_param: error, missing_return: error, unused_import: warning, dead_code: warning }
  plugins: [custom_lint]
linter:
  rules:
    - always_declare_return_types
    - avoid_dynamic_calls
    - cancel_subscriptions
    - close_sinks
    - prefer_final_locals
    - unawaited_futures
    - use_super_parameters
    - public_member_api_docs      # hanya untuk packages/daravel (lib/)
```

`daravel_lints` (custom_lint): `no_dart_mirrors`, `no_mutable_static_in_app` (statik non-final/non-const di `lib/app/**`), `no_sql_string_interpolation` (interpolasi ke `DB.select/raw/whereRaw`), `no_print_in_app`, `registry_entry_missing` (kelas di folder konvensi tidak terdaftar), `handler_must_return` (handler mengembalikan `void`), `unawaited_in_request` (fire-and-forget tanpa `defer`).

### 11.2 Piramida Test & Suite Konformansi

| Lapisan | Lokasi | Cakupan | Target |
| :-- | :-- | :-- | :-- |
| Unit | `packages/daravel/test/unit` | Container, Radix, Grammar, Rule, Cron, parser | ≥ 90% baris modul inti |
| Integrasi | `packages/daravel/test/integration` | DB nyata (SQLite + Postgres via `docker compose` di CI), coordinator multi-isolate, server socket nyata | Skenario kunci |
| **Konformansi** | `packages/daravel/test/conformance` (dibagikan ke app lewat `daravel_test`) | Semantik Laravel yang **dikunci**: format 422/401/403/404/419/429, paginator, resource wrapping, token Sanctum, tabel migrasi, nama kolom timestamp, urutan middleware, `nullable/confirmed/sometimes`, pesan validasi default, JSON tanggal, `apiResource` nama & param | 100% lulus; perubahan = ADR |
| E2E starter | `apps/daravel_starter/test/feature` | Alur register/login/me/logout, 422, 401, throttle, binary AOT smoke (`build/server` dijalankan & di-curl) | CI setiap commit |
| Arsitektur | `test/architecture_test.dart` | Batas impor modul, tidak ada `dart:mirrors`, API publik `final/interface/base` | CI |
| Benchmark | `bench/` | Regresi > 10% gagal nightly | Nightly |

### 11.3 Kebijakan API Publik & Versi

- Semua kelas publik memakai class modifier (`final`, `interface`, `base`, `sealed`) agar perubahan internal tidak menjadi breaking; ekstensi pengguna lewat interface yang disediakan.
- `@experimental` untuk API tier-2 baru; deprecation minimal dua rilis minor dengan `@Deprecated` + pesan migrasi; SemVer ketat setelah 1.0; `CHANGELOG.md` otomatis dari *conventional commits*.
- `dart doc` lengkap untuk `lib/` publik (lint `public_member_api_docs`); contoh di dokumentasi adalah **file test yang dikompilasi** (`doc/examples/*_test.dart`) sehingga tidak basi.

### 11.4 CI/CD Matrix

OS: Linux (utama), Windows, macOS · Dart: `3.9` (minimum) dan `stable` · DB: SQLite (selalu), Postgres 16 (service container), MySQL 8 (nightly) · Langkah: `dart pub get` (workspace) → `dart format --set-exit-if-changed` → `dart analyze --fatal-infos` → `custom_lint` → `dart test` (unit+integrasi+konformansi, `--concurrency` penuh) → `dart compile exe` starter + smoke → `registry:check` → `openapi:generate` snapshot → (nightly) bench + MySQL.

### 11.5 Metode Kerja Implementasi

- **Walking skeleton dulu** (Tier 0), lalu **vertical slice** per subsistem dengan *definition of done* (11.6); tidak ada slice baru sebelum slice sebelumnya hijau di CI.
- **Spec-first lewat test**: setiap slice dimulai dari menyalin kontrak Bagian 7 ke test konformansi/unit yang gagal, baru implementasi.
- **ADR untuk setiap deviasi** dari dokumen ini; dokumen ini di-*version* (V2.0, V2.1, …) seiring ADR.
- **Review ganda untuk kode keamanan** (auth, crypt, grammar, tokenizer, trust proxies): dua reviewer (manusia atau agen berbeda) + checklist 9.2.
- **Eksekusi oleh AI** (bila dipakai): satu slice per sesi, selalu diakhiri `dart analyze` + `dart test` + `dart compile exe`; dilarang menandai selesai dengan `TODO`/`UnimplementedError`; setiap API publik baru harus punya test dan doc comment; hasil benchmark dilampirkan bila menyentuh hot path.

### 11.6 Definition of Done (per slice)

1. `dart analyze --fatal-infos` dan `custom_lint` bersih di tiga OS.
2. Unit + integrasi + konformansi hijau terhadap SQLite **dan** Postgres (bila menyentuh DB).
3. Starter app terkompilasi AOT dan smoke test lulus.
4. Dokumentasi API (`dart doc`) + halaman panduan + contoh terkompilasi.
5. Tidak ada regresi benchmark > 10% pada skenario terkait.
6. ADR ditulis bila ada keputusan baru; CHANGELOG diperbarui.
7. Generator `make:*` terkait (bila ada) menghasilkan kode yang lolos analisis dan test template.

---

## 12. Peta Jalan Eksekusi Bertahap

### Tier 0 — Walking Skeleton (±2 minggu)

Container + Zone + root fallback · `Application`/`Builder` minimal · ServerEngine satu isolate · Router statik + param · `Response.json` · `Request.fake` · `TestClient` dasar · SQLite driver + `DB.select` · satu migrasi `users` · `dartisan serve/migrate` minimal · CI (analyze, test, **compile exe + smoke**). **Exit:** `GET /up` dan `GET /api/ping` berjalan dari binary AOT di tiga OS; test feature pertama hijau.

### Tier 1 — Inti (urutan slice, masing-masing dengan DoD 11.6)

| Slice | Isi | Milestone |
| :-- | :-- | :-- |
| S1 | Container lengkap (named/tag/extend/scoped error), Env, Config bertipe, Providers (deferred), ConfigValidator | `0.1` |
| S2 | HTTP lengkap: Request/Response/Headers, body limits, TrustProxies, Cors, middleware registry/alias/priority/terminable, ExceptionHandler + format JSON, timeouts, drain | `0.2` |
| S3 | Radix radix-compressed + constraints + optional + 405 + HEAD/OPTIONS, groups fluent, apiResource/singleton, URL generator + signed, binding eksplisit, `route:list` | `0.2` |
| S4 | Validation: Rule katalog, nested `*`, ValidatedData, FormRequest, DSL parser, pesan `en`/`id` | `0.3` |
| S5 | Grammar (sqlite/postgres/mysql-compiled-only) + AST + raw named binding + QueryBuilder lengkap + paginators + Postgres pool + tx Zone + savepoint + retry | `0.4` |
| S6 | ORM Hybrid AR: Model, ModelDefinition, casts, dirty, events/observers, soft deletes, scopes, relasi + eager loading + withCount/whereHas, ModelCollection | `0.5` |
| S7 | Schema/Blueprint/Migrator (+ SQLite rebuild), seeders, factories, faker, `make:model/migration/seeder/factory` + registry patcher | `0.5` |
| S8 | Hash (3 driver, compute pool), Crypt, TokenGuard, JwtGuard, AuthManager, Authenticate middleware, Gate/Policy, `can`, login throttling | `0.6` |
| S9 | Multi-isolate: supervisor, shared bind, readiness, respawn, coordinator; Cache stores (memory LRU/process/file/db), locks, RateLimiter named + headers, stampede guard | `0.7` |
| S10 | Events (afterCommit, queued listeners), Queue (sync/database/memory) + worker + failed jobs + unique + middleware, Scheduler + cron | `0.8` |
| S11 | API Resources, Responsable, cursor pagination, Storage local/public/memory, Logging channels + redaksi, metrics `/metrics`, health `/up/ready` | `0.8` |
| S12 | CLI lengkap: `new`, hot reload, `build --docker`, `doctor`, generators sisa, `model:sync`, `openapi:generate`, stubs publish | `0.9` |
| S13 | `daravel_test` lengkap (RefreshDatabase tx, fakes, Clock, assertions), `daravel_lints`, architecture tests | `0.9` |
| S14 | Suite konformansi final, benchmark harness, dokumentasi situs, starter template `api`/`minimal`, audit keamanan 9.3 | `1.0.0-beta` |

### Tier 2 — Perluasan (pasca-beta)

Session/CSRF/SPA-cookie · `daravel_redis` (cache/queue/lock/rate limit cluster) · `daravel_s3` · `daravel_mail` · Localization · SSE/WebSocket + broadcast · OpenTelemetry · MySQL driver · `daravel_shelf` · HTTP client facade + fake · `client:generate` Dart SDK · Crypt mode kompatibel Laravel · email verification & password reset lengkap · Pulse-lite inspector.

### Tier 3 — Opsional

Views (mustache + typed HTML builder) · Notifications · Job batches/chains lanjutan · Protokol Pusher untuk Echo · Full-text search abstraction (Scout-like) · Multi-tenancy helpers · GraphQL adapter (komunitas).

---

## 13. Risiko & Mitigasi

| Risiko | Kemungkinan | Dampak | Mitigasi |
| :-- | :-- | :-- | :-- |
| Scope terlalu luas untuk tim kecil | Tinggi | Tinggi | Tiering ketat; 1.0 = Tier 1 saja; slice dengan DoD; fitur T2/T3 ditunda tanpa rasa bersalah |
| Ekspektasi "Eloquent penuh" tak terpenuhi tanpa refleksi | Sedang | Tinggi | Hybrid AR + generator; dokumentasi "deviasi yang disengaja"; suite konformansi sebagai bukti |
| Coordinator isolate menjadi bottleneck/single point of failure | Sedang | Sedang | Hanya untuk operasi kecil (rate limit/lock); fail-open/closed terdefinisi; metrik latensi; opsi `cluster` Redis |
| `mysql_client` tak terawat | Tinggi | Sedang | MySQL di Tier 2; abstraksi driver; kesiapan vendoring/fork; evaluasi `mysql_dart` lain saat T2 dimulai |
| `sqlite3` native lib di deploy | Sedang | Sedang | `doctor`, Dockerfile referensi, Postgres sebagai default produksi |
| Hot reload VM Service rapuh pada kasus tertentu | Sedang | Rendah | Fallback restart otomatis; `--restart-only` |
| Nama/merek bentrok (`dartisan` placeholder) | Rendah | Sedang | `dartisan_cli` sebagai nama paket; upaya transfer nama; verifikasi merek |
| Kompetisi (`vania` aktif) | Tinggi | Sedang | Diferensiasi teknis nyata (4.2), kualitas test/doc, jalur migrasi Laravel (4.4), komunitas Indonesia |
| Perubahan bahasa Dart (augmentations/dot shorthands) mengubah ergonomi | Rendah | Rendah | Desain tidak bergantung fitur yang belum rilis; adopsi bertahap bila tersedia |
| Kesalahan keamanan di crypto/auth buatan sendiri | Sedang | Sangat tinggi | Pakai primitif `cryptography`/`crypto` (tidak menulis algoritma sendiri), review ganda, test vektor uji standar (RFC test vectors untuk HMAC/Argon2/AES-GCM), audit eksternal sebelum 1.0 |
| Performa Zone/facade lebih buruk dari harapan | Rendah | Sedang | Microbenchmark awal di Tier 0; mode bebas-facade sebagai jalur alternatif |

---

## 14. Pertanyaan Terbuka — Dijawab dengan Rekomendasi (Revisi V2.1)

> Konteks baru yang mengubah jawaban: **tujuan utama Daravel adalah mempermudah perpindahan Laravel → Daravel dan Daravel → Laravel** lewat generator dua arah bernama **`daragic`** (Daravel magic / Laravel magic), termasuk konversi *package* Laravel menjadi package Daravel. Desain `daragic` dirinci di Bagian 16. Jawaban di bawah sudah memperhitungkan tujuan ini.

| # | Pertanyaan | Rekomendasi | Alasan |
| :-- | :-- | :-- | :-- |
| 1 | Nama paket | **Dart:** `daravel` (inti), `dartisan_cli` (executable `dartisan`), `daragic` (generator sisi Dart; nama **bebas** di pub.dev per 23 Okt 2026), satelit `daravel_mysql`, `daravel_blade`, `daravel_redis`. **PHP/Packagist:** vendor `daravel` **bebas**; paket `daravel/daragic` (ekstraktor + emitter sisi Laravel) dan `daravel/daragic-attributes` (atribut anotasi tanpa runtime). Ajukan transfer nama `dartisan` ke pemilik placeholder 2017 lewat pub.dev; bila gagal, tetap `dartisan_cli`. Daftarkan nama GitHub org `daravel` segera. | Nama pendek & konsisten lintas ekosistem; `daragic` satu nama untuk dua arah (`daragic to-daravel`, `daragic to-laravel`) sesuai keinginan pemilik proyek |
| 2 | Lisensi | **MIT** untuk framework, CLI, dan `daragic`. Tambahkan klausul eksplisit di README: **kode hasil generate milik pengguna** tanpa kewajiban lisensi tambahan; header lisensi asli **dipertahankan** pada kode hasil konversi package pihak ketiga. | Laravel MIT; AGPL (seperti `dartian`) menghambat adopsi komersial; generator yang menyentuh kode pihak ketiga butuh kejelasan lisensi |
| 3 | Prioritas MySQL | **Naik ke Tier 1** (ADR-019 menggantikan ADR-013). Koeksistensi Laravel + Daravel di satu database mustahil tanpa MySQL/MariaDB karena mayoritas aplikasi Laravel memakainya. Driver: evaluasi `mysql_dart` 3.0.2 (rilis 21 Okt 2026) dan `mysql1` 0.22.0 (rilis 14 Okt 2026) — keduanya **terawat aktif** (koreksi atas asumsi V2 bahwa hanya `mysql_client` 2022 yang ada). Kriteria pilih: pure Dart, `caching_sha2_password`, prepared statements, TLS, pooling, MariaDB 10.11+ & MySQL 8.4. Bungkus di `daravel_mysql` agar driver dapat diganti tanpa API berubah. CI: MySQL 8.4 + MariaDB 11 sebagai service container **setiap commit** (bukan nightly). | Pasar migrasi = MySQL; risiko pemeliharaan turun karena ada ≥2 driver aktif |
| 4 | Bahasa dokumentasi | **Inggris-utama**, Indonesia sebagai terjemahan kelas satu yang dirilis bersamaan untuk halaman inti. Format setiap halaman: **side-by-side Laravel ↔ Daravel** (kolom kiri PHP, kolom kanan Dart). Dokumen internal (blueprint, ADR) tetap Indonesia. | Halaman side-by-side adalah *parity table* yang terbaca manusia dan menjadi sumber kasus uji `daragic`; jangkauan pub.dev/global butuh Inggris |
| 5 | Aplikasi pilot | Dua pilot sekaligus: (a) **satu aplikasi Laravel internal nyata** milik organisasi pemilik proyek (API + auth + CRUD + beberapa job + sedikit Blade) sebagai *korpus migrasi utama*; (b) **korpus publik** tiga aplikasi Laravel open-source bertingkat (starter API Breeze-style; aplikasi CRUD dengan Spatie permission + queue; aplikasi Blade + Livewire/Inertia) untuk mengukur cakupan `daragic` secara terbuka. Urutan slice Tier 1 disesuaikan: S5 (DB) mencakup MySQL; S8 auth lebih awal dari S9; Blade compile masuk Tier 2 awal. | Generator hanya bisa diukur terhadap korpus nyata; angka cakupan jadi KPI produk |
| 6 | Target deploy | **Primer: container** (Docker/Compose → k8s/Cloud Run); **sekunder: VM + systemd single-binary** karena mayoritas hosting Laravel di Indonesia adalah VM/nginx/PHP-FPM. Sediakan **runbook koeksistensi**: nginx memecah trafik per prefix (`/api/v2/*` → Daravel, sisanya → PHP-FPM), DB & Redis dibagi, prefix cache/session disamakan. Windows Server didukung (binary AOT Windows) untuk instansi yang memakainya. | Migrasi bertahap per endpoint membutuhkan topologi berdampingan, bukan *big bang* |
| 7 | Views | **Naik ke Tier 2 sebagai mesin template kompatibel Blade** (`daravel_blade`, ADR-018), **bukan** mustache. Sintaks Blade dipakai apa adanya (`.blade.php` tetap sumber kebenaran) dan **dikompilasi ke kode Dart saat scaffold-time** (`dartisan view:compile`, otomatis di hot reload), sehingga runtime AOT tidak butuh parser template. Subset gelombang 1: `{{ }}`, `{!! !!}`, `@if/@elseif/@else/@unless/@isset/@empty`, `@foreach/@forelse/@for/@while` + `$loop`, `@extends/@section/@yield/@parent/@include/@includeWhen`, `@auth/@guest/@can`, `@csrf/@method`, `@json`, `@php` (blok PHP → **ditandai manual**), komponen `<x-*>` dan `@component` di gelombang 2. Livewire **tidak** didukung (perlu runtime Livewire di Dart); Inertia **didukung** lewat adapter (hanya respons JSON + header). | Tanpa Blade, migrasi aplikasi web Laravel mustahil; kompilasi scaffold-time menjaga prinsip AOT & tanpa magic; file Blade yang sama bisa dipakai kembali saat kembali ke Laravel (dua arah gratis) |
| 8 | Kompatibilitas Laravel sebagai janji resmi | **Ya, dijadikan "Kontrak Kompatibilitas" berversi**: `Daravel 1.x ⇔ semantik Laravel 11/12`; `daragic` mendukung proyek Laravel 10–12 dan PHP 8.2+. Diuji oleh **CI lintas-runtime**: container PHP (Laravel referensi) + Daravel terhadap MySQL/Postgres yang sama, memverifikasi hash, token Sanctum, tabel `migrations`, payload `Crypt`, format JSON, sesi (T2). Setiap rilis Laravel mayor memicu revisi *parity table* dan rilis minor Daravel. | Kompatibilitas adalah produk itu sendiri; tanpa CI lintas-runtime, janji tidak dapat dipertahankan |

### 14.1 Konsekuensi jawaban terhadap V2 (ringkasan delta, rinci di 16.10)

- ADR-013 (MySQL T2) **digantikan** ADR-019 (MySQL T1 via `daravel_mysql`).
- Views pindah dari Tier 3 ke Tier 2 sebagai Blade-compatible compiled templates (ADR-018).
- DSL string validasi naik status dari *sugar* menjadi **kelas satu setara** objek `Rule` (ADR-020), karena generator mengemit DSL 1:1 dari Laravel.
- *Parity table* menjadi artefak mesin (`parity.yaml`, ADR-016) dan IR aplikasi (`DAM`, ADR-017) menjadi kontrak bersama framework dan generator.
- Section 12 mendapat jalur paralel **Tier D (daragic)** yang berjalan sejak S5 agar generator tumbuh bersama framework, bukan setelahnya.

## 15. Lampiran

### 15.1 Struktur Workspace V2

```text
daravel_workspace/
├── pubspec.yaml                      # workspace: packages/*, apps/*
├── analysis_options.yaml
├── BLUEPRINT_V2.md · docs/adr/ADR-0xx.md · CHANGELOG.md · SECURITY.md
├── bench/                            # harness + skenario + hasil per rilis
├── packages/
│   ├── daravel/                      # inti (lib/daravel.dart + lib/{foundation,http,routing,validation,database,auth,cache,events,queue,schedule,storage,logging,observability,resources,support}.dart)
│   │   ├── lib/src/<modul>/…
│   │   └── test/{unit,integration,conformance,architecture_test.dart}
│   ├── daravel_test/                 # TestClient, fakes, RefreshDatabase, factories helper, architecture helpers
│   ├── daravel_lints/                # custom_lint rules
│   ├── dartisan_cli/                 # bin/dartisan.dart, lib/commands/**, stubs/**
│   ├── daravel_redis/ daravel_s3/ daravel_mail/ daravel_shelf/   # T2 satelit
│   └── daravel_contracts/            # (T2) DTO/validasi yang dibagi dengan Flutter
└── apps/
    └── daravel_starter/
        ├── bin/{server.dart, dartisan.dart}
        ├── bootstrap/{app.dart, providers.dart, migrations.dart, seeders.dart, commands.dart, jobs.dart, policies.dart, listeners.dart, models.dart, defines.dart}
        ├── config/{app_config.dart, database_config.dart, auth_config.dart, cache_config.dart, queue_config.dart, logging_config.dart, cors_config.dart}
        ├── routes/{api.dart, console.dart}
        ├── lib/app/{http/{controllers,middleware,requests,resources}, models, policies, jobs, events, listeners, observers, providers, rules}
        ├── database/{migrations, seeders, factories, schema}
        ├── lang/{en,id}/
        ├── storage/{app,cache,logs,tmp}
        ├── test/{unit,feature,conformance}
        ├── .env.example · Dockerfile · docker-compose.yml · .github/workflows/ci.yml
        └── stubs/ (opsional, hasil stub:publish)
```

### 15.2 Kode Target Developer Experience (acceptance reference, API V2)

```dart
// bootstrap/app.dart
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath)
        .withEnv(env ?? const {})
        .withProviders(providers)
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withJobs(registerJobs)
        .withPolicies(registerPolicies)
        .withRouting(api: apiRoutes, apiPrefix: '/api', health: '/up')
        .withMiddleware((m) {
          m.trustProxies(cidrs: ['10.0.0.0/8']);
          m.bodyLimits(json: 2 << 20);
          m.alias('throttle', (p) => ThrottleMiddleware.parse(p));
          m.group('api', [const EnsureJsonAccepts(), 'throttle:api']);
        })
        .withExceptions((e) {
          e.render<ModelNotFoundException>((ex, req) => Response.json({'message': 'Resource not found.'}, status: 404));
          e.dontReport<ValidationException>();
        })
        .create();

// routes/api.dart
void apiRoutes(Router r) {
  final auth = AuthController();
  r.group(prefix: '/auth', name: 'auth.', routes: (r) {
    r.post('/register', auth.register).name('register').middleware(['throttle:5,1']);
    r.post('/login', auth.login).name('login').middleware(['throttle:login']);
    r.group(middleware: ['auth:token'], routes: (r) {
      r.get('/me', auth.me).name('me');
      r.post('/logout', auth.logout).name('logout');
    });
  });
  r.model<Post>('post', Post.definition);
  r.apiResource('posts', PostController()).middleware(['auth:token']);
}

// app/http/controllers/auth_controller.dart
final class AuthController extends Controller {
  Future<Object?> register(Request req) async {
    final data = await FormRequest.run(RegisterRequest(), req);
    final user = await DB.transaction(() async => User.create({
      'name': data.string('name'), 'email': data.string('email'),
      'password': await Hash.make(data.string('password')),
    }));
    final token = await Auth.issueToken(user, name: 'api', abilities: ['*']);
    return Response.created({'user': UserResource(user), 'token': token.plainText});
  }

  Future<Object?> login(Request req) async {
    final data = await req.validate({'email': [Rule.required(), Rule.email()], 'password': [Rule.required(), Rule.string()]});
    final user = await User.where('email', data.string('email')).first();
    if (user == null || !await Hash.check(data.string('password'), user.password)) {
      throw ValidationException.withMessages({'email': ['These credentials do not match our records.']});
    }
    return {'user': UserResource(user), 'token': (await Auth.issueToken(user, name: 'api')).plainText};
  }

  Future<Object?> me(Request req) async => UserResource(await req.user<User>());
  Future<Object?> logout(Request req) async { await Auth.revokeCurrentToken(); return Response.noContent(); }
}
```

### 15.3 Koreksi Kontrak V1 (ringkas)

```dart
// V1 (salah)                                  // V2 (benar)
void instance<T Object extends>(T value);       void instance<T extends Object>(T value, {String? name});
abstract class Model<T Model<T extends>> {}     abstract base class Model<T extends Model<T>> {}
class ModelRepository<T Model<T extends>> {}    final class ModelDefinition<T extends Model<T>> {}  // + ModelQuery<T>
Future<Response> handleRequest(Request r);      Future<Response> handle(Request r) async { ... }     // berbadan
```

### 15.4 Dependensi & Versi (tervalidasi 23 Okt 2026)

| Paket | Versi | Peran | Native? |
| :-- | :-- | :-- | :-- |
| `crypto` | ^3.0.7 | SHA-256, HMAC | Tidak |
| `cryptography` | ^2.9.0 | Argon2id, AES-GCM, Ed25519, PBKDF2 | Tidak |
| `bcrypt` | ^1.2.0 | Kompatibilitas `$2y$` | Tidak |
| `postgres` | ^3.5.20 | Driver + pool | Tidak |
| `sqlite3` | ^3.7.1 | Driver dev/test/embedded | **Ya** (libsqlite3) |
| `mime` | ^2.1.0 | MIME & multipart | Tidak |
| `path` | ^1.9.1 | Path | Tidak |
| `meta` | ^1.19.0 | Anotasi | Tidak |
| `clock` | ^1.1.3 | Waktu injectable | Tidak |
| `collection` | ^1.19.1 | Utilitas koleksi | Tidak |
| `uuid` | ^4.6.0 | UUID v4/v7 | Tidak |
| `args` / `mason_logger` / `watcher` / `vm_service` / `yaml` | ^2.7.0 / ^0.3.6 / ^1.2.1 / ^15.4.0 / ^3.1.4 | CLI | Tidak |
| `test` / `lints` / `custom_lint` | ^1.33.0 / ^6.1.0 / ^0.8.1 | Kualitas | Tidak |
| `redis` ^4.1.0 · `minio` ^3.5.8 · `mailer` ^7.2.0 · `shelf` ^1.4.3 · `opentelemetry` ^0.18.11 · `intl` ^0.20.3 | — | Satelit T2 | Tidak |
| `mysql_client` | 0.0.27 (2022) | T2, risiko | Tidak |

### 15.5 Instruksi Ringkas untuk AI Executor (pengganti Bagian 1 V1)

Anda bertindak sebagai *Principal Dart Systems Architect*. Implementasikan Daravel sesuai dokumen ini, **slice per slice** (Bagian 12), dengan aturan non-negosiabel: (1) tanpa `dart:mirrors`, semua kompil ke `dart compile exe`; (2) tanpa `build_runner` bagi pengguna — ergonomi lewat generics, registry eksplisit, dan generator scaffold; (3) semua state per-request/job di Zone scope, singleton harus request-agnostic, state lintas-isolate lewat `process`/`cluster` store; (4) SQL hanya lewat grammar/binding — tidak ada interpolasi nilai; (5) strict analysis bersih, tanpa `TODO`/`UnimplementedError`, setiap API publik bertest dan berdokumentasi; (6) semantik yang dikunci suite konformansi tidak boleh berubah tanpa ADR; (7) keamanan default sesuai Bagian 9.2; (8) setiap slice diakhiri `dart analyze`, `dart test` (SQLite+Postgres), `dart compile exe` + smoke, dan laporan benchmark bila menyentuh hot path. Ketika spesifikasi ambigu, pilih **paritas semantik Laravel**, catat sebagai ADR, dan lanjutkan.

### 15.6 Glosarium

**AOT** — Ahead-of-Time compilation ke binary native. **Zone** — konteks eksekusi async Dart yang mewarisi nilai ke callback. **Isolate** — unit konkurensi Dart dengan heap terpisah. **Coordinator isolate** — isolate yang melayani state `process`-scope. **Scaffold-time generation** — pembuatan kode sekali oleh CLI saat `make:*`. **Registry** — daftar eksplisit kelas yang dikelola CLI. **Konformansi** — test yang mengunci semantik Laravel. **PHC** — Password Hashing Competition string format. **ADR** — Architecture Decision Record. **Walking skeleton** — implementasi end-to-end tertipis yang berjalan. **Slice** — potongan vertikal fitur dengan DoD. **Hybrid Active Record** — model dengan attribute bag + accessor bertipe + metadata statis.

---

---

## 16. `daragic` — Generator Dua Arah Laravel ⇄ Daravel (ringkasan; spesifikasi lengkap di `BLUEPRINT_DARAGIC.md`)

### 16.1 Tujuan, Janji, dan Batas yang Jujur

**Tujuan.** Pemilik proyek Laravel menjalankan satu perintah dan mendapatkan proyek Daravel yang (a) terkompilasi, (b) lolos test yang dikonversi dari test Laravel-nya, dan (c) berperilaku identik di jalur HTTP yang diuji. Arah sebaliknya memberi **jaminan keluar** (exit guarantee): tim yang mencoba Daravel dapat kembali ke Laravel tanpa menulis ulang.

**Janji yang realistis.** Transpilasi PHP arbitrer ke Dart secara umum tidak mungkin (fitur dinamis PHP). Yang **mungkin dan bernilai** adalah memanfaatkan fakta bahwa aplikasi Laravel sangat konvensional: ±80–90% artefak (rute, model, migrasi, FormRequest, resource, policy, job, config, env, seeder, factory, test) bersifat **deklaratif atau berpola** dan dapat diekstrak lewat **introspeksi runtime** Laravel sendiri, bukan parsing teks. Sisanya — badan metode controller/service — ditangani **transpiler subset terbatas** ("Laravel Dialect") dengan penanda `DARAGIC-TODO` dan laporan cakupan. Angka cakupan **diukur pada korpus** (Bagian 14 no. 5), tidak dijanjikan di muka.

**Prinsip.** (1) Introspeksi runtime lebih dulu, AST sebagai pelengkap. (2) Satu representasi perantara (IR) untuk dua arah. (3) Emitter Dart = generator `dartisan` yang sudah ada (tidak ada dua jalur kode). (4) Paritas nama API Daravel–Laravel dijaga secara mesin (`parity.yaml`). (5) Hasil generate selalu **dapat dikompilasi** (konstruksi yang tidak didukung menjadi `throw DaragicTodo(...)` + kode asli sebagai komentar, bukan file rusak). (6) Verifikasi otomatis (test terkonversi + *differential replay*) adalah bagian dari produk, bukan tambahan.

### 16.2 Arsitektur

```text
          LARAVEL (PHP)                                   DARAVEL (Dart)
┌──────────────────────────────┐                 ┌──────────────────────────────┐
│ composer: daravel/daragic    │                 │ pub: daragic + dartisan      │
│  ├─ Extractor (runtime):     │   DAM (IR)      │  ├─ Extractor (runtime):     │
│  │  routes, models, rules,   │ ──────────────▶ │  │  router.routes,           │
│  │  policies, jobs, config,  │  dam.json +     │  │  ModelDefinition, Rule,   │
│  │  migrations, schedule,    │  sources/       │  │  Gate, JobRegistry,       │
│  │  packages                 │ ◀────────────── │  │  Schedule, Config         │
│  ├─ PHP AST (php-parser)     │                 │  ├─ Dart AST (analyzer)      │
│  │  → Dialect IR (expr)      │                 │  │  → Dialect IR (expr)      │
│  ├─ Emitter PHP (stubs)      │                 │  ├─ Emitter Dart (dartisan   │
│  ├─ Blade (dipakai apa adanya)│                │  │   make:* generators)      │
│  └─ Recorder (shadow traffic)│                 │  └─ Replayer + differ        │
└──────────────────────────────┘                 └──────────────────────────────┘
                 ▲                                              ▲
                 └──────────── parity.yaml · equivalence.yaml ──┘
                               (artefak bersama, berversi)
```

Komponen:

| Komponen | Sisi | Tugas |
| :-- | :-- | :-- |
| **Extractor Laravel** | PHP | Boot aplikasi Laravel di mode `daragic` (env `testing`, DB sqlite memori atau `--db`), lalu introspeksi: `Route::getRoutes()` (URI, metode, middleware, aksi, nama, `where`, binding), model via Reflection (`$fillable/$guarded/$casts/$hidden/$appends/$table/$primaryKey/$keyType/$timestamps`, relasi dengan memanggil metode yang mengembalikan `Relation` pada instance kosong → kelas terkait, FK, pivot — teknik `laravel-ide-helper`), FormRequest (`rules()/messages()/authorize()` dieksekusi dengan request palsu), `Gate::policies()`, job/listener via pemindaian kelas terdaftar + `EventServiceProvider`, `config()` penuh, `Schedule` (`schedule:list`), skema DB aktual (`Schema::getColumns/getIndexes/getForeignKeys`, Laravel 11+) **dan** file migrasi (AST) untuk urutan historis, package terpasang (`composer.lock`) |
| **DAM (Daravel Application Model)** | IR | Dokumen JSON berversi (`damVersion: 1`) yang menggambarkan aplikasi secara deklaratif (16.3); plus folder `sources/` berisi badan metode dalam **Dialect IR** |
| **Dialect IR** | IR | AST ekspresi/pernyataan bahasa-netral untuk subset Laravel (16.6); node yang tidak diketahui disimpan sebagai `Opaque(sourceLang, text)` |
| **Emitter Dart** | Dart | Memakai generator `dartisan make:*` + stub yang sama dengan pengguna manusia → proyek Daravel standar (registry terisi otomatis) |
| **Emitter PHP** | PHP | Stub Laravel standar (`make:*` Artisan di-*replay*) + penulisan ulang badan metode dari Dialect IR |
| **Extractor Daravel** | Dart | Hampir gratis: semua objek Daravel sudah introspeksibel (ADR-002, ADR-011, 7.10.8); `dartisan daragic:export` menulis DAM; badan metode via `package:analyzer` |
| **`parity.yaml`** | bersama | Pemetaan simbol Laravel ↔ Daravel (kelas, metode, helper, rule, middleware alias, event, exception) dengan catatan semantik dan versi (16.5) |
| **`equivalence.yaml`** | bersama | Pemetaan package pihak ketiga PHP ↔ Dart (16.8) |
| **Recorder/Replayer** | keduanya | Rekam trafik HTTP nyata (request/response/DB snapshot) di Laravel, putar ulang ke Daravel, diff terstruktur (16.9) |

### 16.3 DAM — Skema IR (cuplikan)

```yaml
damVersion: 1
source: { framework: laravel, version: "12.4", php: "8.3", extractedAt: 2026-10-23T08:00:00Z }
app: { name: Inventaris, timezone: Asia/Makassar, locale: id, key: "env:APP_KEY" }
config: { app: {...}, database: {...}, auth: {...}, cache: {...}, queue: {...}, custom: { inventaris: {...} } }
models:
  - name: Product
    fqcn: App\Models\Product            # ↔ lib/app/models/product.dart
    table: products
    key: { name: id, type: autoInt }
    fillable: [sku, name, price, category_id]
    casts: { price: decimal:2, meta: array, published_at: datetime }
    hidden: []
    timestamps: true
    softDeletes: true
    relations:
      - { name: category, type: belongsTo, related: Category, foreignKey: category_id, ownerKey: id }
      - { name: tags, type: belongsToMany, related: Tag, pivot: product_tag, withTimestamps: true }
    scopes: { published: { source: "sources/models/Product.scopePublished.ir.json" } }
    events: { observers: [ProductObserver] }
routes:
  - { method: [GET], uri: api/products, action: { controller: App\Http\Controllers\ProductController, method: index }, name: products.index, middleware: [api, auth:sanctum, throttle:api], where: {} }
  - { method: [POST], uri: api/products, action: {...}, name: products.store, formRequest: StoreProductRequest }
validation:
  StoreProductRequest: { authorize: { source: "..." }, rules: { sku: "required|string|max:32|unique:products,sku", price: "required|numeric|min:0" }, messages: {} }
migrations:
  - { name: 2024_01_01_000000_create_products_table, up: { schema: [...] }, down: {...}, source: "..." }
schema: { tables: [...] }            # keadaan aktual DB (untuk schema:diff)
policies: { Product: { fqcn: App\Policies\ProductPolicy, abilities: [viewAny, view, create, update, delete] } }
jobs: [{ name: SyncStock, fqcn: App\Jobs\SyncStock, props: { productId: int }, tries: 3, backoff: [10, 60], queue: default }]
events: { ProductCreated: { listeners: [NotifyWarehouse], queued: [NotifyWarehouse] } }
schedule: [{ kind: command, name: "inventory:reconcile", cron: "0 2 * * *", withoutOverlapping: true }]
views: [{ name: products.index, path: resources/views/products/index.blade.php, directives: [...], unsupported: [] }]
packages: [{ name: spatie/laravel-permission, version: 6.x, tier: B, equivalence: daravel_permission }]
tests: [{ class: Tests\Feature\ProductApiTest, kind: feature, source: "..." }]
```

DAM adalah **kontrak publik berversi** (JSON Schema diterbitkan), sehingga pihak ketiga dapat menulis extractor/emitter untuk framework lain di masa depan (misal Symfony → DAM).

### 16.4 Pipeline Laravel → Daravel

1. **`daragic analyze`** (di proyek Laravel) — *pre-migration linter*: menghasilkan **Migration Readiness Score** dan daftar konstruksi yang tidak didukung per file (raw SQL kompleks, `__call` magic, Livewire, `eval`, paket Tier C), dengan **saran refactor di PHP** sebelum migrasi (mis. "pindahkan `DB::raw` ke query builder", "tambahkan tipe PHPStan level ≥ 6"). Skor ini adalah alat *go/no-go* dan estimasi usaha manual.
2. **`daragic export --out=dam/`** — introspeksi + AST → `dam.json` + `sources/` + salinan `resources/views`, `lang`, `.env.example`, test.
3. **`dartisan daragic:import dam/ --into=./daravel-app`** — membuat proyek (`dartisan new`) lalu memanggil generator `make:*` untuk setiap entitas; menulis config bertipe **dan** overlay map mekanis (ADR-007); menulis `routes/api.dart`/`web.dart`; mengompilasi Blade (ADR-018); menulis test terkonversi ke `test/feature`; mengisi `MIGRATION_REPORT.md` (cakupan per file, daftar `DARAGIC-TODO` dengan tautan baris).
4. **`dartisan daragic:verify`** — `dart analyze`, `dart test` (test terkonversi), `schema:diff` (migrasi Daravel vs skema Laravel aktual pada DB kosong), dan `replay` bila rekaman tersedia (16.9).
5. **Iterasi manual** pada `DARAGIC-TODO`; `daragic` **tidak pernah menimpa** region yang sudah diedit manusia (marker region, ADR-002) sehingga ekspor ulang dari Laravel yang masih berkembang dapat digabung (*incremental re-import*).

### 16.5 `parity.yaml` — Artefak Paritas Mesin (ADR-016)

```yaml
parityVersion: 1
laravel: "12.x"   daravel: "1.x"
symbols:
  - { php: "Illuminate\\Http\\Request::validate(array)", dart: "Request.validate(Map<String, List<Rule>>)", async: true, note: "string rules → Rule.parse" }
  - { php: "Model::where(col, op?, val)", dart: "Model.where(col, op, [val])", async: false }
  - { php: "Builder::firstOrFail()", dart: "ModelQuery.firstOrFail()", async: true, throws: "ModelNotFoundException" }
  - { php: "response()->json(data, status)", dart: "Response.json(data, status:)", async: false }
  - { php: "abort(int, string?)", dart: "abort(int, [String?])" }
  - { php: "auth()->user()", dart: "await Auth.user()", async: true }
  - { php: "Str::slug", dart: "Str.slug" }
  - { php: "collect(array)->map(fn)", dart: "Collection.of(iterable).map(fn)" }
  - { php: "DB::transaction(Closure)", dart: "DB.transaction(() async {...})", async: true }
helpers: { php: [env, config, route, url, now, abort, dd, collect, optional, tap, value, blank, filled], dart: [env, config, route, url, now, abort, dd, collect, tap, value, blank, filled], missing: [optional] }
middlewareAliases: { auth: auth, "auth:sanctum": "auth:token", throttle: throttle, can: can, signed: signed, verified: verified }
exceptions: { ModelNotFoundException: ModelNotFoundException, AuthorizationException: AuthorizationException, ValidationException: ValidationException }
```

Aturan desain framework yang ditegakkan oleh `parity.yaml`: setiap API publik Daravel yang memiliki padanan Laravel **harus** terdaftar di sini (test arsitektur memverifikasi simbol di `parity.yaml` benar-benar ada di Daravel). Dokumentasi side-by-side (Bagian 14 no. 4) **dibangkitkan** dari file ini plus contoh. Dengan demikian paritas sintaks naik dari "disukai" menjadi **terukur**.

### 16.6 Transpiler Subset Terbatas ("Laravel Dialect")

**Didukung (gelombang 1)** — konstruksi yang menyusun ≥90% badan metode controller/service konvensional:

| PHP (Laravel) | Dart (Daravel) | Catatan |
| :-- | :-- | :-- |
| `$data = $request->validate([...])` | `final data = await req.validate(Rule.parseMap({...}))` | async disisipkan otomatis; tipe `ValidatedData` |
| `User::where('email', $e)->first()` | `await User.where('email', e).first()` | rantai builder dipetakan 1:1 via parity |
| `$user->posts()->create([...])` | `await user.hasMany<Post>('posts').create({...})` | relasi dari DAM |
| `return response()->json([...], 201)` | `return Response.json({...}, status: 201)` | — |
| `return new UserResource($u)` / `UserResource::collection($q->paginate())` | `return UserResource(u)` / `UserResource.collection(await q.paginate())` | — |
| `DB::transaction(function () use ($x) {...})` | `await DB.transaction(() async {...})` | `use` → closure capture Dart alami |
| `try { } catch (ModelNotFoundException $e) { }` | `try { } on ModelNotFoundException catch (e) { }` | pemetaan exception dari parity |
| `$a ?? $b`, `$a?->b`, `match`, `?:` | `a ?? b`, `a?.b`, `switch` expression, `?:` | — |
| `foreach ($items as $k => $v)` | `for (final MapEntry(:key, :value) in items.entries)` / `for (final v in items)` | bentuk dipilih dari tipe inferensi |
| `compact('a','b')`, `[...$x]`, `array_map`, `in_array`, `str_contains`, `sprintf`, `json_encode` | `{'a': a, 'b': b}`, `[...x]`, `.map`, `.contains`, `contains`, `Str.format`, `jsonEncode` | tabel fungsi bawaan PHP → Dart |
| `"Halo {$u->name}"` | `'Halo ${u.name}'` | — |
| `new Foo($dep)` / constructor injection | `Foo(dep)` / `app.make<Foo>()` | DI constructor → resolusi container |
| `enum Status: string { case A = 'a'; }` | `enum Status { a('a'); const Status(this.value); final String value; }` | — |
| `readonly class`, typed props, named args, `static` | `final class`, fields, named params, `static` | — |
| trait tanpa state dinamis | `mixin` | trait dengan `__call` → TODO |
| `abstract class`/`interface` | `abstract base class`/`abstract interface class` | — |
| `Carbon::now()->addDays(3)` | `now().addDays(3)` | ekstensi DateTime |
| `collect($x)->filter(...)->pluck('id')->unique()->values()` | `Collection.of(x).where(...).pluck('id').unique().toList()` | parity koleksi |
| `$this->authorize('update', $post)` | `await req.authorize('update', [post])` | — |
| `event(new OrderPaid($o))`, `dispatch(new SyncStock($id))` | `await Events.dispatch(OrderPaid(o))`, `await Queue.dispatch(SyncStock(id))` | async |
| `Cache::remember('k', 60, fn)` | `await Cache.remember('k', Duration(seconds: 60), () async => ...)` | detik → Duration |

**Tipe array PHP → Dart.** Ambiguitas `array` (list vs map) diselesaikan berurutan: (1) tipe PHPStan/Psalm di docblock (`array<int,string>`, `list<User>`) — **dianjurkan sebelum migrasi**; (2) atribut `#[Daragic\Type('Map<String,int>')]`; (3) inferensi dari literal & penggunaan (`$a[] = x` → List, kunci string → Map); (4) fallback `Map<String, Object?>` + TODO.

**Tidak didukung → `DaragicTodo`** (ditulis sebagai `throw DaragicTodo('alasan')` + sumber PHP sebagai komentar, dan dicatat di laporan): `eval`, variable variables `$$x`, `extract`, `global`, `goto`, referensi `&$x` non-trivial, `new $class`, `$obj->$method()`, `__get/__set/__call` kustom di luar Eloquent, `func_get_args`, resource handles, `static::` late binding yang bergantung subclass dinamis, closure binding `Closure::bind`, `unserialize` objek, kode yang bergantung pada urutan autoload/`include`.

**Arah Dart → PHP** memakai subset yang sama dengan pemetaan terbalik (`parity.yaml` simetris). Tipe statis Dart menghasilkan PHP 8.2+ bertipe (readonly, enum, named args). Pola Dart yang tidak punya padanan PHP (records, pattern matching destrukturisasi kompleks, isolates, `sealed` exhaustiveness) diturunkan ke PHP setara atau ditandai `LARAGIC-TODO`. Badan metode Dart yang memakai `await` dipetakan ke sinkron PHP (model Laravel sinkron).

### 16.7 Anotasi (Petunjuk dari Pengguna)

- **PHP**: paket `daravel/daragic-attributes` (tanpa dependensi runtime): `#[Daragic\Type('List<Map<String,int>>')]`, `#[Daragic\Skip]`, `#[Daragic\Replace(dart: 'return Response.noContent();')]`, `#[Daragic\Model(keyType: 'uuid', table: 'x')]`, `#[Daragic\Relation(type: 'hasManyThrough', related: Post::class, through: Author::class)]` bila tidak terinferensi, `#[Daragic\Json]` untuk array yang harus jadi JSON, `#[Daragic\Equivalent(dart: 'package:excel/excel.dart')]` pada import pihak ketiga, `#[Daragic\Nullable]`. Docblock PHPStan dihormati tanpa atribut apa pun — jalur termurah bagi tim.
- **Dart**: metadata `@laragic.Type('array<string,int>')`, `@laragic.Skip()`, `@laragic.Replace(php: '...')`, `@laragic.Sync()`.
- Anotasi **tidak pernah wajib**; hanya menaikkan cakupan. `daragic analyze` menyarankan anotasi tepat pada baris yang membutuhkannya.

### 16.8 Standar Package & Konversi Package (DPS)

- **Daravel Package Standard** (`daravel.yaml` di root package Dart): `provider:` (kelas ServiceProvider), `config:` (kelas config + default), `migrations:`, `routes:`, `commands:`, `middlewareAliases:`, `publishes:` (aset/stub), `views:` (Blade), `lang:`, `compat: { laravel: "vendor/package@^6.0" }`. `dartisan vendor:publish` dan registry bootstrap membaca manifest ini (tanpa autodiscovery runtime; `dart pub` memberi daftar paket terpasang, `dartisan package:discover` menulis entri registry).
- **Konversi package Laravel** (`daragic package:convert vendor/name`): package dipasang ke aplikasi Laravel *scratch*, diekstrak seperti aplikasi (provider: bindings, alias, rute, migrasi, config, command, publishes, middleware, Blade), lalu diemit sebagai package Dart dengan `daravel.yaml`. Tiga tier hasil:
  - **Tier A** — murni konvensi Laravel (mis. package yang hanya menambah model/rute/migrasi/config): konversi penuh otomatis.
  - **Tier B** — bergantung pada pustaka PHP yang punya padanan Dart terdaftar di `equivalence.yaml` (contoh pemetaan yang **harus diverifikasi** saat implementasi: `guzzlehttp/guzzle → Http facade (package:http)`, `nesbot/carbon → ekstensi DateTime Daravel`, `predis/predis → daravel_redis`, `league/flysystem → Storage`, `laravel/sanctum → bawaan TokenGuard`, `spatie/laravel-permission → daravel_permission (port resmi)`, `intervention/image → package:image`, `maatwebsite/excel → package:excel`, `barryvdh/laravel-dompdf → package:pdf`): konversi otomatis + adapter yang dibangkitkan + TODO terarah.
  - **Tier C** — logika PHP-spesifik berat (ekstensi C, FFI PHP, Livewire, Horizon UI): hanya kerangka + laporan; port manual atau "tidak relevan di Daravel" (mis. Horizon → `queue:monitor`/Pulse-lite).
- **Package resmi "port"**: untuk 10 package Laravel terpopuler (permission, media library, activity log, backup, query builder, sluggable, excel, dompdf, scout, socialite) Daravel menyediakan port resmi bertahap di organisasi `daravel`, sehingga `equivalence.yaml` punya target nyata.
- Lisensi: kode hasil konversi menyertakan header lisensi asli + `NOTICE`; package non-MIT/Apache/BSD diblokir dengan peringatan.

### 16.9 Verifikasi Migrasi

1. **Test terkonversi** — `Tests\Feature\*` (`$this->postJson()->assertStatus()->assertJson()`) dipetakan 1:1 ke `TestClient` (API 7.11 memang dirancang paralel); `RefreshDatabase`, factories, `actingAs`, `Event::fake()`, `Queue::fake()` punya padanan langsung. Hasil: **test lama = spesifikasi migrasi**; hijau berarti perilaku terjaga.
2. **Differential replay (shadow traffic)** — middleware perekam `daravel/daragic` (opsional, hanya di staging) menyimpan `request + response + seed DB` ke `recordings/`; `dartisan daragic:replay` memutar ulang ke Daravel dengan DB seed yang sama dan menghasilkan diff JSON terstruktur (abaikan field volatil: timestamps, token, id acak — daftar dikonfigurasi). Ini menguji kode yang **tidak** punya test.
3. **`schema:diff`** — migrasi Daravel dijalankan di DB kosong, dibandingkan kolom/indeks/FK dengan skema Laravel aktual; perbedaan tipe (mis. `decimal` presisi) dilaporkan.
4. **Laporan** `MIGRATION_REPORT.md`: skor kesiapan, cakupan per lapisan (rute 100%, model 98%, controller 74%…), daftar TODO terurut prioritas, estimasi jam manual (heuristik per jenis TODO), dan checklist koeksistensi.
5. **Koeksistensi** — runbook: nginx split per prefix, DB bersama (migrasi hanya dari **satu** sisi pada satu waktu, lock tabel `migrations`), Redis prefix sama (`cache`, `session` T2), queue dipisah per nama (`php` vs `dart`), feature flag per rute untuk cut-over bertahap dan rollback instan.

### 16.10 Dampak ke Arsitektur V2 (ADR tambahan & override)

| ADR | Keputusan | Menggantikan/Mengubah |
| :-- | :-- | :-- |
| **ADR-016** | `parity.yaml` artefak mesin; test arsitektur memverifikasi; dokumentasi side-by-side dibangkitkan darinya | Memperkuat P8 (paritas semantik) menjadi paritas sintaks terukur |
| **ADR-017** | DAM (IR) berversi dengan JSON Schema publik; extractor Daravel bawaan (`dartisan daragic:export`) | Modul 7.10.8 OpenAPI menjadi salah satu *consumer* DAM |
| **ADR-018** | Views = Blade-compatible compiled templates (`daravel_blade`), Tier 2 awal; `.blade.php` sebagai sumber; `view:compile` scaffold-time + hot reload | Mengganti rencana mustache (Tier 3) di 2.4 dan 7.10 |
| **ADR-019** | MySQL/MariaDB Tier 1 via `daravel_mysql` (driver kandidat `mysql_dart` 3.x / `mysql1` 0.22) dengan CI setiap commit | Menggantikan ADR-013 |
| **ADR-020** | DSL string validasi kelas satu (parse saat definisi, objek `Rule` sama) | Merevisi ADR-011 (DSL bukan lagi sekadar sugar) |
| **ADR-021** | Config mode mekanis: `config/*.dart` sebagai `Map` literal 1:1 dari array PHP + kelas bertipe opsional di atasnya | Melengkapi ADR-007 |
| **ADR-022** | Pemetaan path deterministik dua arah: `App\Http\Controllers\UserController` ⇔ `lib/app/http/controllers/user_controller.dart`; `resources/views/a/b.blade.php` ⇔ `resources/views/a/b.blade.php` (sama) | Struktur 15.1 mendapat folder `resources/views`, `resources/lang` |
| **ADR-023** | Kontrak Kompatibilitas berversi + CI lintas-runtime (PHP + Dart, DB bersama) | Memformalkan 4.4 dan jawaban no. 8 |

Perubahan pada Bagian 12: tambah jalur paralel **Tier D (daragic)** — D0 (bersamaan S5–S7): `analyze` + `export` + import struktural (model, migrasi, rute, request, config, env, test skeleton); D1 (bersamaan S8–S11): transpiler Dialect gelombang 1 + konversi test + `schema:diff`; D2 (Tier 2 awal): Blade compile + package Tier A/B + replay + arah balik struktural; D3: arah balik badan metode + package arah balik + port package resmi.

### 16.11 Risiko Khusus `daragic`

| Risiko | Mitigasi |
| :-- | :-- |
| Janji berlebihan ("konversi 100%") merusak kredibilitas | Skor kesiapan & laporan cakupan sebagai bagian wajib; dokumentasi memakai angka korpus nyata |
| Paritas rusak saat Laravel/Daravel berevolusi | `parity.yaml` berversi per pasangan rilis; test arsitektur + CI lintas-runtime gagal bila simbol hilang |
| Transpiler menghasilkan kode yang kompil tetapi salah secara halus (semantik PHP vs Dart: `==` longgar, integer overflow, string numerik, `null` di aritmetika) | Tabel perbedaan semantik eksplisit dalam transpiler (emit `looseEquals()` helper, `int` 64-bit, konversi eksplisit), test diferensial, peringatan di laporan untuk setiap konstruksi "semantik berbeda" |
| Biaya pemeliharaan dua extractor | DAM sebagai kontrak tunggal; extractor Daravel hampir gratis karena introspeksi bawaan |
| Lisensi & hak kode package pihak ketiga | Header lisensi dipertahankan, blokir lisensi tidak kompatibel, `NOTICE` otomatis |
| Fitur PHP dinamis dalam package populer (Tier C) | Port resmi untuk 10 package terpopuler; tier C transparan sejak `analyze` |

---

*Akhir BLUEPRINT V2.1 (2026-10-23). V2.0 → V2.1: Bagian 14 dijawab, Bagian 16 (`daragic`) ditambahkan, ADR-016…023 menimpa keputusan yang disebut di 16.10.*
