<p align="center">
  <img src="https://img.shields.io/badge/-%E2%9A%A1%20Daravel-0D1117?style=for-the-badge&logoColor=white" alt="Daravel" height="48">
</p>

<h1 align="center">Daravel</h1>

<p align="center">
  <strong>The Laravel developer experience, compiled to a single native binary.</strong><br>
  A Laravel-inspired, AOT-native backend framework for Dart.
</p>

<p align="center">
  <a href="https://github.com/teoprayoga/daravel/actions/workflows/ci.yml"><img src="https://github.com/teoprayoga/daravel/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%5E3.9-0175C2?logo=dart&logoColor=white" alt="Dart ^3.9"></a>
  <a href="https://dart.dev/tools/dart-compile#exe"><img src="https://img.shields.io/badge/AOT-native%20binary-16A34A" alt="AOT native binary"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/status-Tier%200%20walking%20skeleton-F59E0B" alt="Status: Tier 0">
</p>

<p align="center">
  <a href="#about-daravel">About</a> ·
  <a href="#laravel--daravel-at-a-glance">Laravel ↔ Daravel</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#project-structure">Structure</a> ·
  <a href="#dartisan-cli">dartisan</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="#blueprints">Blueprints</a>
</p>

---

## About Daravel

Daravel is a backend framework for Dart that follows the **Laravel 11/12 philosophy**: expressive
and elegant syntax, batteries included, and conventions that make common tasks disappear. It keeps
what makes Laravel loved and adds what only Dart can offer:

- **A single native binary.** `dart compile exe` produces one self-contained executable with
  millisecond startup. No interpreter, no FPM, no build step for your users.
- **Static types, everywhere.** Routes, validation, configuration and models are checked by the
  Dart analyzer before a request is ever served.
- **Octane-grade concurrency, by design.** Every request runs in an isolated `Zone` scope; worker
  isolates saturate all CPU cores without shared mutable state.
- **Zero magic at build time.** No `dart:mirrors`, no `build_runner`. Laravel ergonomics come from
  generics, explicit registries and scaffold-time generation (`dartisan make:*`).
- **Laravel parity where it matters.** Error payloads, paginator JSON, personal access tokens,
  migration tables and password hashes are wire- and storage-compatible, so Laravel and Daravel
  can run side by side on the same database.

Daravel is accessible, powerful, and designed for teams that already think in Laravel.

> **Status.** Tier 0 walking skeleton: container and zone scopes, application builder, HTTP kernel,
> radix router, SQLite access, schema migrations, `TestClient`, CLI and a three-OS CI pipeline.
> See the [roadmap](#roadmap) for what comes next.

## Laravel ↔ Daravel at a glance

Daravel keeps Laravel's names and semantics and adapts only the syntax to Dart.

<table>
<tr>
<th width="50%">Laravel (PHP)</th>
<th width="50%">Daravel (Dart)</th>
</tr>
<tr>
<td>

```php
// bootstrap/app.php
return Application::configure(basePath: __DIR__)
    ->withRouting(api: __DIR__.'/../routes/api.php', health: '/up')
    ->withMiddleware(fn (Middleware $m) => $m->append(RequestId::class))
    ->withExceptions(fn (Exceptions $e) => $e->render(...))
    ->create();
```

</td>
<td>

```dart
// bootstrap/app.dart
Application createApp() => Application.configure(basePath: '.')
    .withRouting(api: apiRoutes, health: '/up')
    .withMiddleware((m) => m.use(const [RequestIdMiddleware()]))
    .withExceptions((e) => e.render<MyException>(...))
    .create();
```

</td>
</tr>
<tr>
<td>

```php
// routes/api.php
Route::prefix('auth')->name('auth.')->group(function () {
    Route::post('/login', [AuthController::class, 'login'])->name('login');
    Route::middleware('auth:sanctum')->group(function () {
        Route::get('/me', [AuthController::class, 'me'])->name('me');
    });
});
```

</td>
<td>

```dart
// routes/api.dart
router.group(prefix: '/auth', name: 'auth.', (r) {
  r.post('/login', auth.login).name('login');
  r.group(middleware: ['auth:token'], (r) {
    r.get('/me', auth.me).name('me');
  });
});
```

</td>
</tr>
<tr>
<td>

```php
public function store(Request $request)
{
    $data = $request->validate([
        'email'    => 'required|email|unique:users',
        'password' => 'required|min:8|confirmed',
    ]);

    $user = DB::transaction(fn () => User::create($data));

    return response()->json($user, 201);
}
```

</td>
<td>

```dart
Future<Object?> store(Request request) async {
  final data = await request.validate({
    'email':    [Rule.required(), Rule.email(), Rule.unique('users')],
    'password': [Rule.required(), Rule.min(8), Rule.confirmed()],
  });

  final user = await DB.transaction(() => User.create(data.toMap()));

  return Response.created(user);
}
```

</td>
</tr>
<tr>
<td>

```php
Schema::create('users', function (Blueprint $table) {
    $table->id();
    $table->string('email')->unique();
    $table->timestamps();
});
```

</td>
<td>

```dart
schema.create('users', (table) {
  table.id();
  table.string('email').unique();
  table.timestamps();
});
```

</td>
</tr>
<tr>
<td>

```php
$this->postJson('/api/users', ['email' => 'a@b.c'])
     ->assertCreated()
     ->assertJsonPath('data.email', 'a@b.c');
```

</td>
<td>

```dart
(await client.post('/api/users', json: {'email': 'a@b.c'}))
    .assertCreated()
    .assertJsonPath('data.email', 'a@b.c');
```

</td>
</tr>
</table>

Validation, models and authentication shown above land in the next slices (S4–S8); routing,
migrations, transactions and the test client are available today.

## Quick start

Requires the [Dart SDK](https://dart.dev/get-dart) `^3.9`. On Linux install the SQLite library
(`sudo apt-get install libsqlite3-0`); Windows falls back to the system `winsqlite3.dll`
automatically.

```bash
git clone https://github.com/teoprayoga/daravel.git
cd daravel
dart pub get                                  # resolves the whole workspace

cd apps/daravel_starter
cp .env.example .env
dart run bin/dartisan.dart migrate            # creates database/database.sqlite
dart run bin/dartisan.dart serve              # http://127.0.0.1:8000
```

```bash
curl http://127.0.0.1:8000/up                 # {"status":"ok","app":"Daravel",...}
curl http://127.0.0.1:8000/api/ping           # {"message":"pong",...}
```

Ship it as a native binary:

```bash
dart compile exe bin/server.dart -o build/server   # build/server.exe on Windows
dart run tool/smoke.dart build/server              # boots the binary and probes /up and /api/ping
```

## Project structure

The starter application mirrors the Laravel 12 layout, so a Laravel developer is never lost:

```text
apps/daravel_starter/
├── bin/
│   ├── server.dart              # HTTP entrypoint (compiles to the native binary)
│   └── dartisan.dart            # project-bound CLI
├── bootstrap/
│   └── app.dart                 # Application.configure(...) — routing, middleware, exceptions
├── routes/
│   └── api.dart                 # mounted under /api
├── lib/app/
│   └── http/controllers/        # controllers are plain classes; handlers are method tear-offs
├── database/
│   └── migrations/              # m_<timestamp>_<name>.dart, registered explicitly in bootstrap
├── test/feature/                # TestClient-based feature tests (in-memory SQLite)
└── tool/smoke.dart              # AOT binary smoke test used by CI
```

The monorepo is a Dart pub workspace:

| Package | Purpose |
| :-- | :-- |
| [`packages/daravel`](packages/daravel) | Framework core: container, application, HTTP, routing, database, schema, facades |
| [`packages/daravel_test`](packages/daravel_test) | Testing toolkit: `TestClient` and Laravel-style fluent assertions |
| [`packages/dartisan_cli`](packages/dartisan_cli) | The `dartisan` command-line interface |
| [`apps/daravel_starter`](apps/daravel_starter) | Reference application and end-to-end tests |

## dartisan CLI

```bash
dart run bin/dartisan.dart serve [--host=127.0.0.1] [--port=8000]
dart run bin/dartisan.dart route:list
dart run bin/dartisan.dart migrate
dart run bin/dartisan.dart migrate:status
dart run bin/dartisan.dart migrate:rollback [--step=1]
dart run bin/dartisan.dart migrate:reset
```

```text
+----------+-----------------+------------+------------+
| Method   | URI             | Name       | Middleware |
+----------+-----------------+------------+------------+
| GET|HEAD | /up             |            |            |
| GET|HEAD | /api/ping       | ping       |            |
| GET|HEAD | /api/users/{id} | users.show |            |
+----------+-----------------+------------+------------+
```

Generators (`make:model`, `make:controller`, …), `dartisan new`, hot reload and `dartisan build`
arrive with slice S12.

## Architecture in brief

- **Container + Zone scopes.** `Container.runScoped('request', …)` stores the scope in a child
  `Zone`; facades resolve the zone container first and fall back to the per-isolate root, so
  `DB`, `Config` and `Log` work in requests, commands, jobs and tests alike.
- **Request lifecycle.** Global middleware → radix-tree routing (static › param › wildcard, with
  backtracking) → route middleware → handler → automatic response conversion. `404`, `405`
  (with `Allow`), `HEAD` and `OPTIONS` behave exactly like Laravel.
- **Zone-aware transactions.** `DB.transaction(() async { … })` puts the transaction executor in
  the zone; every query inside the callback joins it without passing a handle around.
- **Secure by default.** Parameterised SQL only, validated identifiers in DDL, request ids on every
  response, graceful shutdown with a draining `/up` endpoint.

## Roadmap

| Tier | Scope | State |
| :-- | :-- | :-- |
| **0** | Walking skeleton: container, HTTP kernel, router, SQLite, migrations, test client, CLI, CI | ✅ done |
| **1** | Validation & FormRequests, Hybrid Active Record ORM with relations, PostgreSQL/MySQL, auth (Sanctum-style tokens, JWT), Gate/Policy, cache & rate limiting, queue & scheduler, API resources, generators, hot reload | 🚧 next (slices S1–S14) |
| **2** | Sessions/CSRF, Redis, S3, mail, localization, SSE/WebSockets, OpenTelemetry, Blade-compatible compiled views | planned |
| **daragic** | Bidirectional Laravel ⇄ Daravel generator: runtime introspection → IR → generated project, converted tests, differential replay | designed |

## Blueprints

The design is documented before it is built. Decisions are recorded as ADRs and are binding:

- [`BLUEPRINT_V2.md`](BLUEPRINT_V2.md) — architecture, module specifications, security, performance,
  quality gates and the slice-by-slice execution plan.
- [`BLUEPRINT_DARAGIC.md`](BLUEPRINT_DARAGIC.md) — the Laravel ⇄ Daravel generator: intermediate
  representation, extractors, transpiler semantics, Blade compiler, verification and packaging.
- [`BLUEPRINT_V1.md`](BLUEPRINT_V1.md) — the original specification, kept for history.

## Quality gates

Every commit runs on Linux, Windows and macOS: `dart format --set-exit-if-changed`,
`dart analyze --fatal-infos` with strict casts, inference and raw types, `dart test` for every
package, `dart compile exe` of the starter and a smoke test against the resulting binary.

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
(cd packages/daravel && dart test)
(cd apps/daravel_starter && dart test)
```

## Contributing

Daravel is in its foundation phase and welcomes discussion on the blueprints as much as code.
Open an issue to propose a change to an ADR, or a pull request for a slice that follows the
Definition of Done in `BLUEPRINT_V2.md` §11.6. Commits use DCO sign-off.

## Security vulnerabilities

If you discover a security vulnerability, please report it privately via GitHub Security
Advisories instead of opening a public issue. All reports are reviewed promptly.

## License

Daravel is open-source software licensed under the [MIT license](LICENSE).
