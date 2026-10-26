<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel/README.id.md)

A Laravel-inspired, AOT-native backend framework for Dart. Routing,
middleware, validation with Laravel's rules and messages, a query builder and
an Eloquent-style ORM, migrations, Sanctum-compatible tokens, JWT, gates,
cache, queues, events, a scheduler, API resources, storage and structured
logging, served by one native executable that scales across isolates.

Laravel and Daravel can share a database: error and pagination JSON, Sanctum
tokens, bcrypt hashes, `Crypt` payloads and the framework tables use
Laravel's formats, locked by a conformance suite.

## Why Daravel?

1. **One native bundle.** `dartisan build` compiles the app ahead of time,
   with SQLite bundled by a build hook: no SDK, PHP-FPM or Node.js on the
   server. It serves its first request about 14 ms after starting, and worker
   isolates share the compiled code (about 11 MB idle with one worker, 12 MB
   with four, on a Linux CI runner).
2. **No reflection, no `build_runner`.** Generators write plain Dart into
   explicit registries, so the compiler sees exactly what you read.
3. **Every core on one port.** A supervisor runs N worker isolates, respawns
   crashes and drains on `SIGTERM`; a coordinator isolate keeps locks, the
   `process` cache and rate limits correct across workers without Redis.
4. **Request state stays in its request.** Requests, jobs and commands run in
   their own `Zone` scope; transactions are zone-aware, with savepoints and
   after-commit dispatch.
5. **Runs next to Laravel** on the same SQLite or PostgreSQL database
   (or MySQL and MariaDB with `daravel_mysql`), so an application can move
   [endpoint by endpoint](https://github.com/daravel-dev/daravel/blob/main/docs/guide/migrating-from-laravel.md).
6. **Routes that document themselves.** `.validates(...)` and `.returns(...)`
   enforce 403/422 before the handler and generate OpenAPI 3.1.
7. **Guard rails included.** Hashing in compute isolates, AST lints against
   SQL interpolation and reflection, and security and conformance suites.

| Laravel | Daravel |
| :-- | :-- |
| `Route::post('/posts', [PostController::class, 'store'])` with `StorePostRequest $request` | `router.post('/posts', posts.store).validates(const StorePostRequest())` |
| `$request->validated()` | `request.validated()` |
| `$request->integer('page', 1)` | `await request.integer('page', 1)` |
| `User::where('active', true)->paginate()` | `await User.query().where('active', true).paginate()` |
| `DB::transaction(fn () => ...)` | `await DB.transaction(() async => ...)` |

## Get started

The fastest way is the CLI, which creates a complete project:

```bash
dart pub global activate dartisan_cli
dartisan new blog
cd blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch
```

Or add the framework to an existing package:

```bash
dart pub add daravel
```

```dart
import 'package:daravel/daravel.dart';

Application createApp() => Application.configure(basePath: '.')
    .withRouting(
      apiPrefix: '/api',
      api: (router) {
        router.get('/ping', (_) => {'message': 'pong'});
        router.post('/users', (request) async {
          final data = await request.validate({
            'email': 'required|email|unique:users',
            'password': 'required|min:8|confirmed',
          });
          return Response.created(data.toMap());
        });
      },
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
```

See [`example/main.dart`](example/main.dart) and the
[documentation](https://github.com/daravel-dev/daravel/blob/main/docs/guide/index.md),
including the [Laravel ⇄ Daravel parity table](https://github.com/daravel-dev/daravel/blob/main/docs/guide/parity.md).

## Related packages

- [`dartisan_cli`](https://pub.dev/packages/dartisan_cli): project creation, dev server with hot reload, generators, migrations, native builds.
- [`daravel_test`](https://pub.dev/packages/daravel_test): `TestClient`, assertions, database helpers, fakes and Laravel conformance matchers.
- [`daravel_lints`](https://pub.dev/packages/daravel_lints): AST lint rules for Daravel applications.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" and "Flutter"
are trademarks of Google LLC. Daravel is an independent project, not
affiliated with or endorsed by either.
