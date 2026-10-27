<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/svg/daravel-logo-horizontal-on-dark.svg">
    <img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/svg/daravel-logo-horizontal-on-light.svg" alt="Daravel Framework" height="84">
  </picture>
</p>

<p align="center">
  English · <a href="https://github.com/daravel-dev/daravel/blob/main/packages/daravel/README.id.md">Bahasa Indonesia</a>
</p>

<p align="center">
  <strong>The Laravel developer experience, compiled to a single native binary.</strong><br>
  <em>A Laravel-inspired, AOT-native backend framework for Dart with routing, validation, ORM, auth, queues, and wire compatibility.</em>
</p>

<p align="center">
  <a href="https://daravel.dev"><img src="https://img.shields.io/badge/website-daravel.dev-FF2D20?logo=globe&logoColor=white" alt="Official Website"></a>
  <a href="https://pub.dev/packages/daravel"><img src="https://img.shields.io/pub/v/daravel.svg?label=pub.dev&color=0175C2&logo=dart&logoColor=white" alt="pub.dev version"></a>
  <a href="https://pub.dev/packages/daravel/score"><img src="https://img.shields.io/pub/points/daravel?color=16A34A&label=pub%20points" alt="pub points"></a>
  <a href="https://pub.dev/packages/daravel"><img src="https://img.shields.io/pub/popularity/daravel?color=blue" alt="popularity"></a>
  <a href="https://github.com/daravel-dev/daravel/actions/workflows/ci.yml"><img src="https://github.com/daravel-dev/daravel/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%5E3.13-0175C2?logo=dart&logoColor=white" alt="Dart ^3.13"></a>
  <a href="https://dart.dev/tools/dart-build"><img src="https://img.shields.io/badge/AOT-native%20bundle-16A34A" alt="AOT native"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="https://daravel.dev">Documentation</a> ·
  <a href="#why-daravel">Why Daravel</a> ·
  <a href="#laravel--daravel-at-a-glance">Laravel ↔ Daravel</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#batteries-included-showcase">Features</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#ecosystem">Ecosystem</a>
</p>

---

## About Daravel

**Daravel** brings the beloved developer experience of **Laravel 11/12** to Dart and Flutter developers. It combines expressive, elegant syntax and convention-over-configuration with the unrivaled superpowers of the Dart runtime: **single-binary AOT compilation**, static types from routes to database queries, and **multi-isolate concurrency** across all CPU cores on a single port.

Daravel is built to **coexist side-by-side with Laravel on the same database**: error payloads, paginator JSON, Sanctum personal access tokens, `$2y$` bcrypt hashes, `Crypt` payloads, and framework tables share the exact same wire format, locked by a rigorous conformance suite.

---

## Why Daravel?

```
┌────────────────────────────────────────────────────────────────────────┐
│                      DARAVEL RUNTIME ARCHITECTURE                      │
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
│                     ├─ Atomic Locks (no Redis needed)                  │
│                     ├─ Fixed-Window Rate Limiter & Leases              │
│                     └─ L1 Near-Cache & Multi-Worker State              │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

1. **⚡ One Native Bundle (14 ms Cold Boot & 11 MB RAM):**  
   `dartisan build` compiles your entire backend into machine code with SQLite embedded via native build hooks. No Dart SDK, PHP-FPM, or Node.js runtime required on the server.
2. **🛡️ Zero Reflection, Zero `build_runner`:**  
   Unlike traditional Dart frameworks, Daravel requires no code-generation wait loops. The CLI writes explicit, clean Dart registries that the AOT compiler sees directly.
3. **🚀 Every Core on One Port Without Redis:**  
   A supervisor isolate orchestrates worker isolates with automatic crash respawn and graceful `SIGTERM` draining. A dedicated coordinator isolate maintains atomic locks, rate-limits, and in-memory caches across all workers without an external Redis instance.
4. **🔒 Zone-Scoped State Isolation:**  
   Every request, queue job, and command runs in its own Dart `Zone` scope. Facades (`Auth`, `DB`, `Cache`, `Log`) resolve transparently per request. `DB.transaction` is zone-aware: nested transactions become savepoints, and queued jobs wait for the outer commit.
5. **🤝 100% Laravel Coexistence:**  
   Migrate from Laravel [endpoint by endpoint](https://daravel.dev/migrating-from-laravel.html) behind a reverse proxy. Both frameworks can read and write to the same SQLite, PostgreSQL, or MySQL database without conflict.
6. **📖 Self-Documenting Routes & OpenAPI 3.1:**  
   `.validates(StorePostRequest())` and `.returns(PostResource.schema)` enforce validation before the handler runs, populate `request.validated()`, and generate interactive OpenAPI 3.1 documentation automatically.
7. **📱 Full-Stack Flutter Client Generation:**  
   `dartisan client:flutter` generates type-safe Dart/Flutter API clients that share the server's validation rules on mobile devices before network transmission.

---

## Laravel ↔ Daravel at a Glance

Daravel keeps Laravel's names, semantics, and design patterns, adapting only the syntax to idiomatic modern Dart:

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

## Batteries-Included Showcase

### 1. Expressive Routing with Automatic Validation & OpenAPI

```dart
// routes/api.dart
router.post('/assessments', assessmentController.store)
  .validates(const StoreAssessmentRequest())
  .returns(AssessmentResource.schema, status: 201)
  .middleware(const ['auth:sanctum', 'throttle:60,1']);
```

### 2. Eloquent-Style ORM with Eager Loading & Savepoints

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

    // Nested transaction automatically becomes a SQL savepoint:
    await DB.transaction(() async {
      await record.auditLogs().create({'action': 'created'});
    });

    return record;
  });

  // Dispatched only after the outer transaction successfully commits:
  AssessmentCreated(assessment).dispatch();

  return Response.created(AssessmentResource(assessment));
}
```

### 3. Asynchronous Queues & Background Workers

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

## Quick Start

### Option A: The Dartisan CLI (Recommended)

Create a production-ready application with generators, migrations, and live-reloading:

```bash
# 1. Install Dartisan globally
dart pub global activate dartisan_cli

# 2. Scaffold a new Daravel project
dartisan new my_app
cd my_app

# 3. Run database migrations & seeders
dartisan migrate --seed

# 4. Start the dev server with Hot Reload
dartisan serve --watch
```

### Option B: Add to an Existing Package

```bash
dart pub add daravel
```

Create `bin/server.dart`:

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

Run with native performance:
```bash
dart run bin/server.dart
```

---

## The Daravel Ecosystem

The Daravel framework is designed around modular, high-cohesion packages:

| Package | pub.dev | Description |
| :--- | :--- | :--- |
| **[`daravel`](https://pub.dev/packages/daravel)** | [![pub](https://img.shields.io/pub/v/daravel.svg)](https://pub.dev/packages/daravel) | Core framework: Router, ORM, Auth, Queues, Mail, Cache, Supervisor |
| **[`dartisan_cli`](https://pub.dev/packages/dartisan_cli)** | [![pub](https://img.shields.io/pub/v/dartisan_cli.svg)](https://pub.dev/packages/dartisan_cli) | CLI developer tool: generators, dev server, migration engine, native builds |
| **[`daravel_test`](https://pub.dev/packages/daravel_test)** | [![pub](https://img.shields.io/pub/v/daravel_test.svg)](https://pub.dev/packages/daravel_test) | Testing toolkit: `TestClient`, database fakes, Laravel wire conformance |
| **[`daravel_lints`](https://pub.dev/packages/daravel_lints)** | [![pub](https://img.shields.io/pub/v/daravel_lints.svg)](https://pub.dev/packages/daravel_lints) | AST-based lint rules against reflection, SQL interpolation, and memory leaks |
| **[`daravel_mysql`](https://pub.dev/packages/daravel_mysql)** | [![pub](https://img.shields.io/pub/v/daravel_mysql.svg)](https://pub.dev/packages/daravel_mysql) | High-performance MySQL & MariaDB driver |
| **[`daravel_permission`](https://pub.dev/packages/daravel_permission)** | [![pub](https://img.shields.io/pub/v/daravel_permission.svg)](https://pub.dev/packages/daravel_permission) | Database roles & permissions on spatie/laravel-permission's tables |
| **[`daravel_teorion`](https://pub.dev/packages/daravel_teorion)** | [![pub](https://img.shields.io/pub/v/daravel_teorion.svg)](https://pub.dev/packages/daravel_teorion) | Request-driven query filters with whitelists (laravel-teorion) |
| **[`daravel_livekit`](https://pub.dev/packages/daravel_livekit)** | [![pub](https://img.shields.io/pub/v/daravel_livekit.svg)](https://pub.dev/packages/daravel_livekit) | LiveKit server SDK: access tokens, rooms and participants, verified webhooks |
| **[`daravel_redis`](https://pub.dev/packages/daravel_redis)** | [![pub](https://img.shields.io/pub/v/daravel_redis.svg)](https://pub.dev/packages/daravel_redis) | Redis & Valkey across servers: cache, locks, rate limits, queues, broadcasting |
| **[`daravel_postgres`](https://pub.dev/packages/daravel_postgres)** | [![pub](https://img.shields.io/pub/v/daravel_postgres.svg)](https://pub.dev/packages/daravel_postgres) | High-performance PostgreSQL driver with binary float8 support |
| **[`daravel_sqlite`](https://pub.dev/packages/daravel_sqlite)** | [![pub](https://img.shields.io/pub/v/daravel_sqlite.svg)](https://pub.dev/packages/daravel_sqlite) | Embedded SQLite driver bundled with native build hooks |

---

## Documentation & Community

Comprehensive documentation and interactive guides are available at the official website:
👉 **[https://daravel.dev](https://daravel.dev)**

- [Getting Started & Installation](https://daravel.dev/getting-started.html)
- [Routing & Middleware](https://daravel.dev/routing.html)
- [Validation & Form Requests](https://daravel.dev/validation.html)
- [Database & Eloquent ORM](https://daravel.dev/database.html)
- [Authentication & Sanctum Tokens](https://daravel.dev/auth.html)
- [Laravel ⇄ Daravel Parity Table](https://daravel.dev/parity.html)
- [Migrating from Laravel (Strangler Fig)](https://daravel.dev/migrating-from-laravel.html)

## License & Trademarks

- **License:** Open-source software licensed under the [MIT License](https://github.com/daravel-dev/daravel/blob/main/LICENSE).
- **Trademarks:** "Laravel" is a trademark of Laravel Holdings Inc. "Dart" and "Flutter" are trademarks of Google LLC. Daravel is an independent open-source project and is not affiliated with or endorsed by Laravel Holdings Inc. or Google LLC.
