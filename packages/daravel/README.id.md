<!-- source: README.md sha256:4fc47c31ae35 -->
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/svg/daravel-logo-horizontal-on-dark.svg">
    <img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/svg/daravel-logo-horizontal-on-light.svg" alt="Daravel Framework" height="84">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/daravel-dev/daravel/blob/main/packages/daravel/README.md">English</a> · Bahasa Indonesia
</p>

<p align="center">
  <strong>Pengalaman developer Laravel, dikompilasi menjadi satu biner native.</strong><br>
  <em>Framework backend terinspirasi Laravel untuk Dart dengan routing, validasi, ORM, autentikasi, queue, dan kompatibilitas format.</em>
</p>

<p align="center">
  <a href="https://daravel.dev/id/index.html"><img src="https://img.shields.io/badge/website-daravel.dev-FF2D20?logo=globe&logoColor=white" alt="Website Resmi"></a>
  <a href="https://pub.dev/packages/daravel"><img src="https://img.shields.io/pub/v/daravel.svg?label=pub.dev&color=0175C2&logo=dart&logoColor=white" alt="Versi pub.dev"></a>
  <a href="https://pub.dev/packages/daravel/score"><img src="https://img.shields.io/pub/points/daravel?color=16A34A&label=pub%20points" alt="Poin Pub"></a>
  <a href="https://pub.dev/packages/daravel"><img src="https://img.shields.io/pub/popularity/daravel?color=blue" alt="Popularitas"></a>
  <a href="https://github.com/daravel-dev/daravel/actions/workflows/ci.yml"><img src="https://github.com/daravel-dev/daravel/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%5E3.13-0175C2?logo=dart&logoColor=white" alt="Dart ^3.13"></a>
  <a href="https://dart.dev/tools/dart-build"><img src="https://img.shields.io/badge/AOT-native%20bundle-16A34A" alt="AOT native"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="Lisensi: MIT"></a>
</p>

<p align="center">
  <a href="https://daravel.dev/id/index.html">Dokumentasi</a> ·
  <a href="#mengapa-daravel">Mengapa Daravel</a> ·
  <a href="#laravel--daravel-sekilas">Laravel ↔ Daravel</a> ·
  <a href="#arsitektur">Arsitektur</a> ·
  <a href="#fitur-lengkap-bawaan">Fitur</a> ·
  <a href="#mulai-cepat">Mulai Cepat</a> ·
  <a href="#ekosistem">Ekosistem</a>
</p>

---

## Tentang Daravel

**Daravel** menghadirkan pengalaman developer (*DX*) terbaik dari **Laravel 11/12** ke ekosistem Dart dan Flutter. Daravel memadukan sintaks elegan dan konvensi *batteries-included* dengan keunggulan teknis runtime Dart: **kompilasi AOT ke satu biner native**, *type-safety* dari rute hingga database, serta **konkurensi multi-isolate** di seluruh core CPU pada satu port.

Daravel dirancang untuk **berjalan berdampingan dengan Laravel di database yang sama**: format JSON error, paginasi, token Sanctum, hash bcrypt `$2y$`, payload `Crypt`, dan tabel-tabel framework menggunakan format identik yang dikunci oleh rangkaian uji konformansi.

---

## Mengapa Daravel?

```
┌────────────────────────────────────────────────────────────────────────┐
│                      ARSITEKTUR RUNTIME DARAVEL                        │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│   HTTP Client Request  ──►  [:8000] Supervisor Engine                  │
│                                      │                                 │
│        ┌─────────────────────────────┼─────────────────────────────┐   │
│        ▼                             ▼                             ▼   │
│   Worker Isolate #1             Worker Isolate #2             Worker #N│
│   ┌─────────────────┐           ┌─────────────────┐          ┌────────┐│
│   │ Zone Request    │           │ Zone Request    │          │  Zone  ││
│   │ ├─ Auth Context │           │ ├─ Auth Context │          │ Request││
│   │ ├─ DB Tx / Save │           │ ├─ DB Tx / Save │          │ Context││
│   │ └─ Response     │           │ └─ Response     │          │        ││
│   └────────┬────────┘           └────────┬────────┘          └───┬────┘│
│            │                             │                       │     │
│            └──────────────────────┬──────┴───────────────────────┘     │
│                                   ▼                                    │
│                     Coordinator Isolate (Shared RAM)                   │
│                     ├─ Atomic Locks (tanpa butuh Redis)                │
│                     ├─ Fixed-Window Rate Limiter & Leases              │
│                     └─ L1 Near-Cache & Multi-Worker State              │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

1. **⚡ Satu Bundle Native (Cold Boot 14 ms & 11 MB RAM):**  
   `dartisan build` mengompilasi seluruh aplikasi menjadi kode mesin AOT dengan SQLite tersemat via native build hooks. Server tidak memerlukan Dart SDK, runtime Node.js, maupun PHP-FPM.
2. **🛡️ Tanpa Reflection, Tanpa `build_runner`:**  
   Tidak ada langkah *code generation* yang memakan waktu. CLI menulis kode Dart murni yang eksplisit sehingga langsung terbaca oleh compiler.
3. **🚀 Semua Core di Satu Port Tanpa Redis:**  
   Supervisor isolate mengatur worker isolate dengan auto-respawn saat terjadi *crash* dan penutupan *graceful* pada `SIGTERM`. Coordinator isolate menjaga lock atomik, rate limit, dan cache di memori antar-worker tanpa Redis.
4. **🔒 Isolasi State Berbasis `Zone`:**  
   Setiap request, background job, dan perintah CLI berjalan di dalam scope `Zone` masing-masing. Facade (`Auth`, `DB`, `Cache`, `Log`) meresolve state per-request. Transaksi `DB.transaction` mendukung nested savepoints dan dispatch after-commit.
5. **🤝 100% Koeksistensi dengan Laravel:**  
   Bermigrasi dari Laravel [endpoint demi endpoint](https://daravel.dev/id/migrating-from-laravel.html) di balik reverse proxy. Kedua framework dapat membaca dan menulis ke database SQLite, PostgreSQL, atau MySQL yang sama.
6. **📖 Route yang Mendokumentasikan Dirinya Sendiri:**  
   `.validates(StorePostRequest())` dan `.returns(PostResource.schema)` memvalidasi data sebelum handler berjalan, mengisi `request.validated()`, dan menghasilkan dokumentasi OpenAPI 3.1 otomatis.
7. **📱 Integrasi Klien Flutter Full-Stack:**  
   `dartisan client:flutter` menghasilkan client API Dart/Flutter bertipe dengan aturan validasi server yang langsung aktif di perangkat mobile.

---

## Laravel ↔ Daravel Sekilas

Daravel mempertahankan konvensi, semantik, dan pola desain Laravel, hanya menyesuaikan sintaks ke Dart modern yang ekspresif:

| Laravel 12 (PHP) | Daravel (Dart) |
| :--- | :--- |
| `Route::post('/posts', [PostController::class, 'store'])` | `router.post('/posts', posts.store)` |
| `->middleware(['auth:sanctum', 'throttle:api'])` | `.middleware(const ['auth:sanctum', 'throttle:api'])` |
| `public function rules(): array { return ['email' => 'required\|email']; }` | `Map<String, Object> rules() => {'email': 'required\|email'};` |
| `$request->validate([...])` | `await request.validate({...})` |
| `$request->validated()` | `request.validated()` |
| `User::where('active', true)->paginate(15)` | `await User.query().where('active', true).paginate(15)` |
| `DB::transaction(fn () => ...)` | `await DB.transaction(() async => ...)` |
| `UserRegistered::dispatch($user)` | `UserRegistered(user).dispatch()` |
| `return new UserResource($user)` | `return UserResource(user)` |
| `Auth::user()` / `Auth::id()` | `Auth.user()` / `Auth.id()` |
| `Cache::remember('key', 3600, fn () => ...)` | `await Cache.remember('key', 1.hours, () async => ...)` |

---

## Fitur Lengkap Bawaan

### 1. Routing Deklaratif, Validasi Otomatis & OpenAPI

```dart
// routes/api.dart
router.post('/assessments', assessmentController.store)
  .validates(const StoreAssessmentRequest())
  .returns(AssessmentResource.schema, status: 201)
  .middleware(const ['auth:sanctum', 'throttle:60,1']);
```

### 2. ORM Ala Eloquent dengan Eager Loading & Savepoints

```dart
// app/controllers/assessment_controller.dart
Future<Response> store(Request request) async {
  final data = request.validated();

  final assessment = await DB.transaction(() async {
    final record = await Assessment.create({
      'title': data['title'],
      'score': data['score'],
      'user_id': Auth.id(),
    });

    // Transaksi bersarang otomatis menjadi SQL savepoint:
    await DB.transaction(() async {
      await record.auditLogs().create({'action': 'created'});
    });

    return record;
  });

  // Hanya di-dispatch setelah transaksi luar berhasil di-commit:
  AssessmentCreated(assessment).dispatch();

  return Response.created(AssessmentResource(assessment));
}
```

### 3. Background Queue & Worker Asinkron

```dart
// app/jobs/send_assessment_report_job.dart
final class SendAssessmentReportJob extends Job {
  final int assessmentId;
  const SendAssessmentReportJob(this.assessmentId);

  @override
  int get tries => 3;

  @override
  Duration get backoff => const Duration(seconds: 5);

  @override
  Future<void> handle() async {
    final assessment = await Assessment.findOrFail(assessmentId);
    await Mail.to(assessment.user.email).send(AssessmentReportMail(assessment));
  }
}
```

### 4. Real-Time WebSockets & Server-Sent Events (SSE)

```dart
// routes/web.dart
router.get('/live-feed', (request) {
  return Response.sse((stream) async {
    await for (final event in Event.listen<LiveScoreUpdated>()) {
      stream.send(event: 'score', data: event.toJson());
    }
  });
});
```

---

## Mulai Cepat

### Opsi A: Menggunakan Dartisan CLI (Direkomendasikan)

```bash
# 1. Install Dartisan secara global
dart pub global activate dartisan_cli

# 2. Buat proyek Daravel baru
dartisan new my_app
cd my_app

# 3. Jalankan migrasi dan seeder database
dartisan migrate --seed

# 4. Jalankan dev server dengan Hot Reload
dartisan serve --watch
```

### Opsi B: Tambahkan ke Proyek Dart yang Ada

```bash
dart pub add daravel
```

Buat file `bin/server.dart`:

```dart
import 'package:daravel/daravel.dart';

Application createApp() => Application.configure(basePath: '.')
    .withRouting(
      api: (router) {
        router.get('/ping', (_) => {'status': 'ok', 'framework': 'Daravel'});
        router.post('/echo', (request) async {
          final data = await request.validate({'message': 'required|string'});
          return Response.ok(data.toMap());
        });
      },
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
```

Jalankan dengan performa native AOT:
```bash
dart run bin/server.dart
```

---

## Ekosistem Daravel

Daravel dirancang modular dengan pustaka-pustaka resmi yang terpadu:

| Paket | pub.dev | Deskripsi |
| :--- | :--- | :--- |
| **[`daravel`](https://pub.dev/packages/daravel)** | [![pub](https://img.shields.io/pub/v/daravel.svg)](https://pub.dev/packages/daravel) | Core framework: Router, ORM, Auth, Queues, Mail, Cache, Supervisor |
| **[`dartisan_cli`](https://pub.dev/packages/dartisan_cli)** | [![pub](https://img.shields.io/pub/v/dartisan_cli.svg)](https://pub.dev/packages/dartisan_cli) | CLI developer tool: generator, dev server, mesin migrasi, native builds |
| **[`daravel_test`](https://pub.dev/packages/daravel_test)** | [![pub](https://img.shields.io/pub/v/daravel_test.svg)](https://pub.dev/packages/daravel_test) | Testing toolkit: `TestClient`, fakes database, konformansi Laravel |
| **[`daravel_lints`](https://pub.dev/packages/daravel_lints)** | [![pub](https://img.shields.io/pub/v/daravel_lints.svg)](https://pub.dev/packages/daravel_lints) | Aturan lint AST terhadap reflection, interpolasi SQL, dan kebocoran memori |
| **[`daravel_mysql`](https://pub.dev/packages/daravel_mysql)** | [![pub](https://img.shields.io/pub/v/daravel_mysql.svg)](https://pub.dev/packages/daravel_mysql) | Driver MySQL & MariaDB berkinerja tinggi |
| **[`daravel_permission`](https://pub.dev/packages/daravel_permission)** | [![pub](https://img.shields.io/pub/v/daravel_permission.svg)](https://pub.dev/packages/daravel_permission) | Role & permission di database pada tabel spatie/laravel-permission |
| **[`daravel_teorion`](https://pub.dev/packages/daravel_teorion)** | [![pub](https://img.shields.io/pub/v/daravel_teorion.svg)](https://pub.dev/packages/daravel_teorion) | Query filter dari request dengan whitelist (laravel-teorion) |
| **[`daravel_livekit`](https://pub.dev/packages/daravel_livekit)** | [![pub](https://img.shields.io/pub/v/daravel_livekit.svg)](https://pub.dev/packages/daravel_livekit) | SDK server LiveKit: access token, room dan participant, webhook terverifikasi |
| **[`daravel_redis`](https://pub.dev/packages/daravel_redis)** | [![pub](https://img.shields.io/pub/v/daravel_redis.svg)](https://pub.dev/packages/daravel_redis) | Redis & Valkey lintas server: cache, lock, rate limit, queue, broadcasting |
| **[`daravel_postgres`](https://pub.dev/packages/daravel_postgres)** | [![pub](https://img.shields.io/pub/v/daravel_postgres.svg)](https://pub.dev/packages/daravel_postgres) | Driver PostgreSQL dengan dukungan binary float8 |
| **[`daravel_sqlite`](https://pub.dev/packages/daravel_sqlite)** | [![pub](https://img.shields.io/pub/v/daravel_sqlite.svg)](https://pub.dev/packages/daravel_sqlite) | Driver SQLite bawaan dengan build hook native |

---

## Dokumentasi & Komunitas

Dokumentasi lengkap dan panduan interaktif tersedia di situs resmi:
👉 **[https://daravel.dev](https://daravel.dev)**

- [Panduan Memulai & Instalasi](https://daravel.dev/id/getting-started.html)
- [Routing & Middleware](https://daravel.dev/id/routing.html)
- [Validasi & Form Request](https://daravel.dev/id/validation.html)
- [Database & ORM Eloquent](https://daravel.dev/id/database.html)
- [Autentikasi & Token Sanctum](https://daravel.dev/id/auth.html)
- [Tabel Paritas Laravel ⇄ Daravel](https://daravel.dev/id/parity.html)
- [Migrasi dari Laravel (Strangler Fig)](https://daravel.dev/id/migrating-from-laravel.html)

## Lisensi & Trademark

- **Lisensi:** Perangkat lunak open-source berlisensi [MIT License](https://github.com/daravel-dev/daravel/blob/main/LICENSE).
- **Trademark:** "Laravel" adalah merek dagang dari Laravel Holdings Inc. "Dart" dan "Flutter" adalah merek dagang dari Google LLC. Daravel adalah proyek open-source independen dan tidak terafiliasi dengan Laravel Holdings Inc. maupun Google LLC.
