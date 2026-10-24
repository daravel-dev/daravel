<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/svg/daravel-logo-horizontal-on-dark.svg">
    <img src="docs/brand/svg/daravel-logo-horizontal-on-light.svg" alt="Daravel" height="96">
  </picture>
</p>

<p align="center">
  <strong>The Laravel developer experience, compiled to a single native binary.</strong><br>
  A Laravel-inspired, AOT-native backend framework for Dart.
</p>

<p align="center">
  <a href="https://github.com/teoprayoga/daravel/actions/workflows/ci.yml"><img src="https://github.com/teoprayoga/daravel/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-%5E3.13-0175C2?logo=dart&logoColor=white" alt="Dart ^3.13"></a>
  <a href="https://dart.dev/tools/dart-build"><img src="https://img.shields.io/badge/AOT-native%20bundle-16A34A" alt="AOT native bundle"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/version-1.0.0--beta.1-F59E0B" alt="Version 1.0.0-beta.1">
</p>

<p align="center">
  <a href="#about-daravel">About</a> ·
  <a href="#features">Features</a> ·
  <a href="#laravel--daravel-at-a-glance">Laravel ↔ Daravel</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#project-structure">Structure</a> ·
  <a href="#dartisan-cli">dartisan</a> ·
  <a href="docs/guide/index.md">Docs</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="#design-process">Design</a> ·
  <a href="#brand">Brand</a>
</p>

---

## About Daravel

Daravel is a backend framework for Dart that follows the **Laravel 11/12 philosophy**: expressive
and elegant syntax, batteries included, and conventions that make common tasks disappear. It keeps
what makes Laravel loved and adds what only Dart can offer:

- **A native AOT binary.** `dart build cli` produces a self-contained executable (with SQLite
  bundled next to it) and millisecond startup. No interpreter, no FPM, no build step for your users.
- **Static types, everywhere.** Routes, validation, configuration and models are checked by the
  Dart analyzer before a request is ever served.
- **Octane-grade concurrency, by design.** A supervisor runs N worker isolates on one port; every
  request runs in its own `Zone` scope, and rate limits, locks and metrics stay correct across
  workers through a coordinator isolate.
- **Zero magic at build time.** No `dart:mirrors`, no `build_runner`. Laravel ergonomics come from
  generics, explicit registries and scaffold-time generation (`dartisan make:*`).
- **Laravel parity where it matters.** Error payloads, paginator and resource JSON, personal access
  tokens, password hashes, encrypted payloads and the `migrations`, `cache`, `jobs` and
  `failed_jobs` tables are wire- and storage-compatible, so Laravel and Daravel can run side by
  side on the same database.

> **Status.** Tier 1 in progress: slices S1–S13 are done (foundation, HTTP, routing, validation,
> database, ORM, schema & seeding, auth, multi-isolate serving & cache, queue & scheduler,
> resources, storage & observability, CLI with `new` and hot reload, testing toolkit and lints).
> Next is S14: conformance suite, benchmarks and documentation. The API is not stable yet.

## Features

| Area | What you get today |
| :-- | :-- |
| **Foundation** | Service container with singleton/scoped/transient lifetimes, deferred providers, `.env` + `.env.{APP_ENV}`, typed config sections, boot-time config validation |
| **HTTP** | Middleware pipeline with aliases, groups and priority; trusted proxies, CORS, security headers, body limits, request ids, per-route timeouts, `defer()`, terminable middleware |
| **Routing** | Radix router, constraints, optional params, groups, resources, route model binding, named routes, signed URLs |
| **Validation** | ~50 rules with Laravel presence semantics, wildcards (`items.*.id`), `FormRequest`, Laravel-12 422 payloads, `en`/`id` messages |
| **Database** | Query builder for SQLite, PostgreSQL and MySQL grammars; length-aware, simple and cursor pagination; savepoints; retries; after-commit callbacks |
| **ORM** | Hybrid Active Record: casts, accessors/mutators, scopes, soft deletes, observers, eager loading, `HasOne/HasMany/BelongsTo/BelongsToMany/HasManyThrough` |
| **Schema** | Create and alter tables, foreign keys, SQLite table rebuilds, `migrate:fresh`, seeders, model factories with a built-in faker |
| **Auth** | Argon2id/bcrypt/PBKDF2 hashing off the event loop, AES-256 `Crypt`, Sanctum-compatible tokens, JWT (HS256/EdDSA), multi-guard `auth:token,jwt`, Gate & Policies, `can:` middleware |
| **Concurrency** | Supervisor + workers sharing one port, readiness barrier, respawn with crash-loop detection, coordinator isolate for process-wide state |
| **Cache & limits** | Memory (LRU), process, file and database stores; `remember` with stampede protection, `flexible`, atomic locks; sliding-window rate limiter and `throttle:` |
| **Queue & schedule** | Events with queued listeners, jobs with retries, backoff, timeouts, unique jobs and middleware; sync/memory/database drivers; cron scheduler with overlap protection |
| **API & files** | `JsonResource` with conditional attributes and Laravel `data/links/meta` collections; local/public/memory disks with `Storage.fake()` |
| **Observability** | Channel-based structured logging with request context and secret redaction, Prometheus `/metrics` merged across workers, `/up` and `/up/ready` health probes |
| **Testing** | `TestClient` with `actingAs` and 30+ fluent assertions, `refreshDatabase` (migrate once, roll back every test), database assertions, `Event/Queue/Storage` fakes, `Log.spy()`, time travel via `Clock` |
| **Quality** | `daravel_lints` (no reflection, no `print`, no mutable statics in `lib/app`, no SQL interpolation, unregistered classes) and architecture checks for apps and for the framework's own module graph |
| **Laravel conformance** | Locked Laravel 12 wire and storage formats (errors, pagination, resources, Sanctum tokens, bcrypt, `Crypt`, shared tables), a machine-checked `parity.yaml`, and conformance matchers for your own tests |
| **Security & performance** | A security regression suite (injection, spoofing, JWT, traversal, ReDoS, fuzzing, timing) and a benchmark harness with a nightly regression gate |

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
    ->withSchedule(fn (Schedule $s) => $s->job(new PruneTokens)->daily())
    ->create();
```

</td>
<td>

```dart
// bootstrap/app.dart
Application createApp() => Application.configure(basePath: '.')
    .withRouting(api: apiRoutes, health: '/up')
    .withMiddleware((m) => m.use(const [RequestIdMiddleware()]))
    .withSchedule((s) => s.job(const PruneTokens()).daily())
    .create();
```

</td>
</tr>
<tr>
<td>

```php
// routes/api.php
Route::post('/auth/login', [AuthController::class, 'login'])
    ->middleware('throttle:login');
Route::middleware('auth:sanctum')->group(function () {
    Route::get('/auth/me', [AuthController::class, 'me']);
    Route::patch('/users/{user}', [UserController::class, 'update'])
        ->can('update', 'user');
});
```

</td>
<td>

```dart
// routes/api.dart
router.post('/auth/login', auth.login)
    .middleware(const ['throttle:login']);
router.group(middleware: const ['auth'], (r) {
  r.get('/auth/me', auth.me);
  r.patch('/users/{user}', users.update)
      .middleware(const ['can:update,user']);
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

    $user = DB::transaction(fn () => User::create([
        ...$data, 'password' => Hash::make($data['password']),
    ]));
    UserRegistered::dispatch($user);

    return new UserResource($user);       // 201: recently created
}
```

</td>
<td>

```dart
Future<Object?> store(Request request) async {
  final data = await request.validate({
    'email':    'required|email|unique:users',
    'password': [Rules.required(), Rules.min(8), Rules.confirmed()],
  });

  final user = await DB.transaction(() async => User.create({
    'email': data.string('email'),
    'password': await Hash.make(data.string('password')),
  }));
  await Event.dispatch(UserRegistered(user.id, user.email));

  return UserResource(user);             // 201: recently created
}
```

</td>
</tr>
<tr>
<td>

```php
class SendWelcomeEmail implements ShouldQueue
{
    public $tries = 3;
    public $backoff = [10, 60];

    public function handle(): void { /* … */ }
}

SendWelcomeEmail::dispatch($user)->onQueue('emails');
```

</td>
<td>

```dart
final class SendWelcomeEmail extends Job {
  @override int get tries => 3;
  @override List<Duration> get backoff =>
      const [Duration(seconds: 10), Duration(seconds: 60)];

  @override Future<void> handle(JobContext ctx) async { /* … */ }
}

await Queue.dispatch(SendWelcomeEmail(user.id)).onQueue('emails');
```

</td>
</tr>
<tr>
<td>

```php
$value = Cache::remember('stats', 600, fn () => Stats::compute());

Cache::lock('report')->block(5, function () {
    // exclusive across workers
});
```

</td>
<td>

```dart
final value = await Cache.remember('stats',
    const Duration(minutes: 10), Stats.compute);

await Cache.lock('report').block(const Duration(seconds: 5), () async {
  // exclusive across workers
});
```

</td>
</tr>
<tr>
<td>

```php
$this->postJson('/api/auth/register', $payload)
     ->assertCreated()
     ->assertJsonPath('user.email', 'ana@example.com');

Queue::assertPushed(SendWelcomeEmail::class);
```

</td>
<td>

```dart
(await client.post('/api/auth/register', json: payload))
    .assertCreated()
    .assertJsonPath('user.email', 'ana@example.com');

fake.assertPushed<SendWelcomeEmail>();
```

</td>
</tr>
</table>

## Quick start

Requires the [Dart SDK](https://dart.dev/get-dart) `^3.13` (Flutter 3.47+). No system SQLite is
needed: `package:sqlite3` downloads a hash-verified SQLite build through a build hook and bundles
it with the app (set `hooks: user_defines: sqlite3: source: system` in `pubspec.yaml` to use the
OS library instead).

```bash
git clone https://github.com/teoprayoga/daravel.git
cd daravel
dart pub get                                  # resolves the whole workspace

cd apps/daravel_starter
cp .env.example .env
dart run bin/dartisan.dart key:generate       # writes APP_KEY to .env
dart run bin/dartisan.dart migrate --seed     # users, tokens, cache and jobs tables
dart run bin/dartisan.dart serve --watch      # http://127.0.0.1:8000 with hot reload
```

```bash
curl http://127.0.0.1:8000/up                 # liveness
curl http://127.0.0.1:8000/up/ready           # {"status":"ok","checks":{"database":…,"cache":…}}
curl -X POST http://127.0.0.1:8000/api/auth/register \
     -H 'content-type: application/json' \
     -d '{"name":"Ana","email":"ana@example.com","password":"secret-123","password_confirmation":"secret-123"}'
```

Or start a fresh application from the clone (`--path` points at the framework checkout;
without it the project depends on this repository through git):

```bash
dart run packages/dartisan_cli/bin/dartisan.dart new ../blog --path=.
cd ../blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch
```

Serve on every core and process background work:

```bash
dart run bin/dartisan.dart serve --isolates=4           # supervisor + 4 workers on one port
dart run bin/dartisan.dart queue:work --queue=emails,default
dart run bin/dartisan.dart schedule:work
```

Ship it as a native bundle (`bin/server` plus the bundled SQLite in `lib/`; deploy the directory):

```bash
dart run bin/dartisan.dart build                   # = dart build cli -t bin/server.dart -o build/server
APP_ISOLATES=4 METRICS_ENABLED=true ./build/server/bundle/bin/server
dart run tool/smoke.dart                           # boots the bundle and probes it
dart run bin/dartisan.dart build --docker          # multi-stage Dockerfile, no libsqlite3 needed
```

## Project structure

The starter application mirrors the Laravel 12 layout, so a Laravel developer is never lost:

```text
apps/daravel_starter/
├── bin/
│   ├── server.dart              # HTTP entrypoint (compiles to the native binary)
│   └── dartisan.dart            # project-bound CLI
├── bootstrap/
│   ├── app.dart                 # Application.configure(...): routing, auth, events, schedule
│   ├── migrations.dart          # explicit registries maintained by `dartisan make:*`
│   ├── seeders.dart
│   ├── jobs.dart
│   ├── policies.dart            # registerPolicies(gate)
│   ├── listeners.dart           # registerListeners(events)
│   └── commands.dart            # custom dartisan commands
├── routes/
│   ├── api.dart                 # mounted under /api
│   ├── web.dart
│   └── console.dart             # scheduled tasks
├── lib/app/
│   ├── console/commands/        # custom dartisan commands
│   ├── events/                  # plain event classes
│   ├── http/controllers/        # controllers are plain classes; handlers are method tear-offs
│   ├── http/requests/           # FormRequests
│   ├── http/resources/          # JsonResources
│   ├── jobs/                    # queued jobs
│   ├── listeners/               # event listeners
│   ├── models/                  # Hybrid Active Record models
│   └── policies/                # authorization policies
├── database/
│   ├── migrations/              # m_<timestamp>_<name>.dart
│   ├── factories/
│   └── seeders/
├── test/
│   ├── feature/                 # TestClient and refreshDatabase tests (in-memory SQLite)
│   └── architecture_test.dart   # lints, registry completeness, import rules
└── tool/smoke.dart              # AOT binary smoke test used by CI
```

The monorepo is a Dart pub workspace:

| Package | Purpose |
| :-- | :-- |
| [`packages/daravel`](packages/daravel) | Framework core |
| [`packages/daravel_test`](packages/daravel_test) | Testing toolkit: `TestClient`, assertions, `refreshDatabase`, time travel, architecture helpers |
| [`packages/daravel_lints`](packages/daravel_lints) | AST-based lint rules and registry checks, run by `dartisan lint` and in tests |
| [`packages/dartisan_cli`](packages/dartisan_cli) | The `dartisan` command-line interface and code generators |
| [`apps/daravel_starter`](apps/daravel_starter) | Reference application and end-to-end tests |

## dartisan CLI

| Group | Commands |
| :-- | :-- |
| Project | `new <name> [--template=api\|minimal] [--path] [--git]`, `about`, `doctor [--production]`, `key:generate [--show] [--force]`, `stub:publish` |
| Serve & build | `serve [--host] [--port] [--isolates] [--watch]`, `build [--output] [--with-cli] [--docker]`, `test [--conformance] [--security] [--coverage]`, `route:list [--path] [--method] [--name] [--json]`, `openapi:generate`, `lint [--json]`, `coordinator:stats` |
| Database | `migrate [--seed]`, `migrate:status`, `migrate:rollback [--step]`, `migrate:reset`, `migrate:fresh [--seed] [--force]`, `db:seed [--class] [--all]`, `model:sync [Model] [--dry-run]` |
| Generators | `make:model [-m -f -s -c -p -r --api --all]`, `make:migration`, `make:seeder`, `make:factory`, `make:controller [--api --resource --model]`, `make:request`, `make:middleware`, `make:job`, `make:policy`, `make:event`, `make:listener [--event]`, `make:resource`, `make:rule`, `make:observer`, `make:provider`, `make:command`, `make:test [--unit]` |
| Queue | `queue:work [--queue --tries --backoff --timeout --max-jobs --once]`, `queue:failed`, `queue:retry`, `queue:forget`, `queue:flush`, `queue:clear`, `queue:restart` |
| Schedule | `schedule:run`, `schedule:work`, `schedule:list` |
| Cache & files | `cache:clear [store]`, `storage:link` |

Generators update the registries in `bootstrap/` (migrations, seeders, jobs, policies, listeners
and custom commands) through marked regions, so a new class is wired up the moment it is created.
Every template can be customised after `stub:publish`:

```bash
dart run bin/dartisan.dart make:model Post --all --api
```

```text
created lib/app/models/post.dart
created database/migrations/m_2026_10_24_090507_create_posts_table.dart
updated bootstrap/migrations.dart
created database/factories/post_factory.dart
created database/seeders/post_seeder.dart
updated bootstrap/seeders.dart
created lib/app/http/controllers/post_controller.dart
created lib/app/policies/post_policy.dart
updated bootstrap/policies.dart
created lib/app/http/resources/post_resource.dart
```

## Architecture in brief

- **Container + Zone scopes.** `Container.runScoped('request', …)` stores the scope in a child
  `Zone`; facades resolve the zone container first and fall back to the per-isolate root, so
  `DB`, `Auth`, `Cache` and `Log` work in requests, jobs, commands and tests alike.
- **Request lifecycle.** Global middleware → radix-tree routing → route model binding → route
  middleware → handler → automatic response conversion, then a terminate phase after the response
  is written. `404`, `405` (with `Allow`), `HEAD` and `OPTIONS` behave exactly like Laravel.
- **State scopes (ADR-003).** Every store declares `isolate`, `process` or `cluster` scope. Rate
  limits and locks default to `process` and are served by a coordinator isolate, so
  `throttle:60,1` means 60 per minute for the whole server, not 60 per worker.
- **Zone-aware transactions.** `DB.transaction(() async { … })` puts the transaction executor in
  the zone. Queued jobs and `dispatchAfterCommit` events wait for the commit and are dropped on
  rollback, including nested savepoints.
- **Secure by default.** Parameterised SQL only, hashing in compute isolates, constant-time secret
  comparison, downgrade-resistant hash verification, log redaction, trusted-proxy-aware client IPs.

## Roadmap

| Tier | Scope | State |
| :-- | :-- | :-- |
| **0** | Walking skeleton: container, HTTP kernel, router, SQLite, migrations, test client, CLI, CI | ✅ done |
| **1** | S1 foundation · S2 HTTP hardening · S3 routing · S4 validation · S5 database · S6 ORM · S7 schema, seeding & generators · S8 auth · S9 multi-isolate & cache · S10 events, queue & scheduler · S11 resources, storage & observability · S12 CLI (`new`, hot reload, `build --docker`, `doctor`, `openapi:generate`, `model:sync`, stubs) · S13 testing toolkit, lints & architecture tests | ✅ done |
| **1** | S14 conformance suite, security suite, `parity.yaml`, benchmark harness, documentation site, `api`/`minimal` templates → **1.0.0-beta.1** | ✅ done |
| **2** | Multipart uploads, sessions/CSRF, Redis, S3, mail, localization, SSE/WebSockets, OpenTelemetry, Blade-compatible compiled views | planned |
| **daragic** | Bidirectional Laravel ⇄ Daravel generator: runtime introspection → IR → generated project, converted tests, differential replay | designed |

## Documentation

Guides live in [`docs/guide`](docs/guide/index.md) (English, with Indonesian core pages in
[`docs/guide/id`](docs/guide/id/index.md)): getting started, routing, validation, database,
responses, auth, background work, testing, deployment, Laravel coexistence, security,
performance and the generated [Laravel ⇄ Daravel parity table](docs/guide/parity.md).
`dart run tool/docs/generate.dart` builds the HTML site into `build/site`. Release notes are in
[CHANGELOG.md](CHANGELOG.md).

## Design process

The design is documented before it is built. Architecture, module specifications, the
Laravel ⇄ Daravel generator (`daragic`) and the slice-by-slice plan live in maintainer blueprints,
with decisions recorded as binding ADRs. Code comments refer to them as `BLUEPRINT_V2 §…` and
`ADR-…`. Guidance for AI coding assistants working in this repository is in
[`CLAUDE.md`](CLAUDE.md).

## Brand

<img src="docs/brand/svg/daravel-icon.svg" alt="Daravel icon" width="72" align="right">

The Daravel mark is a geometric dragon: a blue wing and head for Dart, and a red serpentine body
for the Laravel heritage. Icons from 16 to 1024 px, a transparent mark, single-colour versions,
light and dark lockups, a social preview and `favicon.ico` live in [`docs/brand`](docs/brand),
together with usage rules. Every file is generated from geometry in `tool/brand/generate.dart`
(`dart run tool/brand/generate.dart`), so the SVG is the source of truth.

## Quality gates

Every commit runs on Linux, Windows and macOS: `dart format --set-exit-if-changed`,
`dart analyze --fatal-infos` with strict casts, inference and raw types, `dart test` for every
package (including the Laravel conformance suite, the security suite and the `parity.yaml`
check), a docs freshness check, `dart build cli` of the starter and a smoke test against the
resulting binary. Benchmarks run nightly (`bench/`).

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
(cd packages/daravel && dart test)
(cd packages/daravel_lints && dart test)
(cd packages/daravel_test && dart test)
(cd packages/dartisan_cli && dart test)
(cd apps/daravel_starter && dart test)
(cd packages/daravel && dart test --tags conformance)   # Laravel contracts only
(cd packages/daravel && dart test --tags security)      # security suite only
dart run tool/docs/generate.dart --check
```

## Contributing

Daravel is in its foundation phase and welcomes design discussion as much as code. Open an
issue to propose a design change, or a pull request that keeps every quality gate green.
Commits use DCO sign-off.

## Security vulnerabilities

If you discover a security vulnerability, please report it privately as described in
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

Daravel is open-source software licensed under the [MIT license](LICENSE).
