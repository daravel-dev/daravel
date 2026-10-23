# DARAVEL & DARTISAN — MASTER ARCHITECTURE & IMPLEMENTATION BLUEPRINT

> **Framework Name:** `Daravel` (Dart + Laravel 12+ Philosophy)  
> **CLI Tool Name:** `dartisan` (Dart + Artisan)  
> **Target Dart SDK:** `^3.6.0` (AOT-Native, Null-Safe, Records, Pattern Matching, Pub Workspaces)  
> **Runtime Target:** Standalone AOT Native Binary (`dart compile exe`) & JIT Dev Server with Hot-Reload  

---

## 1. SYSTEM INSTRUCTIONS FOR AI EXECUTOR (CLAUDE)

You are acting as a **Principal Dart Systems Architect & Lead Framework Engineer**. Your mission is to implement **Daravel**, a production-grade, scalable, full-featured backend framework in Dart modeled after **Laravel 11/12**, along with its companion CLI tool **`dartisan`**.

### Non-Negotiable Engineering Rules
1. **100% AOT-Native Compatibility (ZERO `dart:mirrors`):**
   - Never import or use `dart:mirrors`. The entire framework and user applications must compile cleanly to a single native binary via `dart compile exe`.
2. **Zero `build_runner` Required for End-Users:**
   - Do not force users to run slow code-generators (`build_runner`) when creating controllers, models, routes, or requests. Achieve Laravel-like ergonomics using Dart 3 generics, closures, records, extension types, and explicit descriptor objects.
3. **Zone-Scoped Concurrency (Zero Cross-Request State Leakage):**
   - Unlike PHP (which dies after each request), Dart is a long-running stateful process (similar to **Laravel Octane**).
   - Every incoming HTTP Request MUST execute inside an isolated `Zone` (`runZoned`).
   - All Facades (`Auth`, `RequestContext`, `DB` active transaction, `Log` context) MUST resolve their request-specific state from `Zone.current` and NEVER from mutable static/global variables.
4. **Multi-Isolate HTTP Scaling:**
   - The HTTP server must support spawning multiple worker `Isolate` instances bound to the same port using `HttpServer.bind(host, port, shared: true)` to saturate all CPU cores.
5. **Strict Typing & Zero Placeholders:**
   - Enforce `strict-casts: true`, `strict-inference: true`, and `strict-raw-types: true`.
   - Never leave `// TODO`, `UnimplementedError()`, or stubbed methods. Every module must be fully implemented and accompanied by unit/integration tests.
6. **SQL Injection Immunity:**
   - Every value passed to `QueryBuilder` (`where`, `whereIn`, `insert`, `update`) MUST use parameterized bindings (`?` normalized to `$1, $2` for PostgreSQL or `?` for SQLite). Raw string interpolation of values in SQL is strictly forbidden.

---

## 2. MONOREPO WORKSPACE STRUCTURE

Use **Dart Pub Workspaces** (`resolution: workspace`) to manage the framework core, CLI, and starter application in a single repository:

```text
daravel_workspace/
├── pubspec.yaml                                  # Workspace Root
├── analysis_options.yaml                         # Strict Lint Rules
├── BLUEPRINT.md                                  # This Architecture Specification
├── packages/
│   ├── daravel_core/                             # The Daravel Framework Engine
│   │   ├── pubspec.yaml
│   │   ├── lib/
│   │   │   ├── daravel_core.dart                 # Main public barrel export
│   │   │   └── src/
│   │   │       ├── foundation/
│   │   │       │   ├── application.dart          # Application & ApplicationBuilder (Laravel 12 style)
│   │   │       │   ├── container.dart            # IoC Container (Singleton, Transient, Zone-Scoped)
│   │   │       │   ├── service_provider.dart     # ServiceProvider contract (register & boot)
│   │   │       │   ├── env.dart                  # .env parser & type-safe lookup
│   │   │       │   └── config.dart               # Dot-notation configuration repository
│   │   │       ├── http/
│   │   │       │   ├── server_engine.dart        # Multi-Isolate HttpServer engine + graceful shutdown
│   │   │       │   ├── kernel.dart               # HTTP Kernel & Request lifecycle orchestrator
│   │   │       │   ├── request.dart              # Rich Request (JSON, Multipart, Query, Headers, IP)
│   │   │       │   ├── response.dart             # Rich Response (JSON, Stream, File, Redirect, Cookies)
│   │   │       │   ├── uploaded_file.dart        # Multipart file wrapper
│   │   │       │   ├── form_request.dart         # Base FormRequest (authorize + rules)
│   │   │       │   └── middleware/
│   │   │       │       ├── middleware.dart       # Middleware interface & Pipeline runner
│   │   │       │       ├── cors_middleware.dart
│   │   │       │       ├── throttle_middleware.dart
│   │   │       │       └── trim_strings_middleware.dart
│   │   │       ├── routing/
│   │   │       │   ├── router.dart               # Fluent Router (get, post, group, apiResource)
│   │   │       │   ├── radix_tree.dart           # High-speed O(k) Radix Tree route matcher
│   │   │       │   ├── route_entry.dart          # Route metadata (name, middleware, handler)
│   │   │       │   └── controller.dart           # Base Controller & ResourceController contract
│   │   │       ├── exceptions/
│   │   │       │   ├── exception_handler.dart    # Fluent ExceptionHandler registry
│   │   │       │   └── http_exceptions.dart      # NotFound, Unauthorized, Forbidden, ValidationException
│   │   │       ├── validation/
│   │   │       │   ├── validator.dart            # Sync & Async Validation Engine
│   │   │       │   └── rules.dart                # Built-in Rules (required, email, min, max, unique, etc.)
│   │   │       ├── database/
│   │   │       │   ├── database_manager.dart     # Connection manager & Zone-aware transaction runner
│   │   │       │   ├── drivers/
│   │   │       │   │   ├── database_driver.dart  # Unified Driver & Transaction contract
│   │   │       │   │   ├── sqlite_driver.dart    # sqlite3 driver (in-memory & file)
│   │   │       │   │   └── postgres_driver.dart  # postgres pool driver
│   │   │       │   ├── query/
│   │   │       │   │   ├── query_builder.dart    # Fluent SQL Builder
│   │   │       │   │   ├── grammar.dart          # SQL Dialect Compiler (? vs $1, identifier quoting)
│   │   │       │   │   └── paginator.dart        # LengthAwarePaginator (Laravel JSON format)
│   │   │       │   ├── orm/
│   │   │       │   │   ├── model.dart            # Base Model<T>
│   │   │       │   │   ├── model_repository.dart # Active-Record style repository & query proxy
│   │   │       │   │   └── relations.dart        # Eager loading helpers (hasMany, belongsTo)
│   │   │       │   └── schema/
│   │   │       │       ├── schema_builder.dart   # Schema.create, Schema.table, Schema.dropIfExists
│   │   │       │       ├── blueprint.dart        # Column definitions & foreign keys
│   │   │       │       └── migrator.dart         # Migration runner (up, rollback, fresh, status)
│   │   │       ├── auth/
│   │   │       │   ├── auth_manager.dart         # Multi-guard authentication manager
│   │   │       │   ├── guards/
│   │   │       │   │   ├── auth_guard.dart       # Guard contract
│   │   │       │   │   ├── jwt_guard.dart        # Stateless HMAC-SHA256 JWT Guard
│   │   │       │   │   └── sanctum_guard.dart    # Stateful Personal Access Token Guard (SHA-256)
│   │   │       │   ├── authenticatable.dart      # Interface for User models
│   │   │       │   ├── auth_middleware.dart      # Authenticate & Ability/Scope check middleware
│   │   │       │   └── hash.dart                 # Password hashing (PBKDF2/Argon2id/Bcrypt + HMAC)
│   │   │       ├── cache/
│   │   │       │   ├── cache_manager.dart        # Cache facade & store manager
│   │   │       │   ├── memory_store.dart         # TTL-aware in-memory cache store
│   │   │       │   └── rate_limiter.dart         # Sliding-window / Token-bucket rate limiter
│   │   │       ├── events/
│   │   │       │   └── event_dispatcher.dart     # Sync & Async typed Event Dispatcher
│   │   │       ├── storage/
│   │   │       │   └── storage_disk.dart         # Local & Cloud file storage abstraction
│   │   │       ├── logging/
│   │   │       │   └── logger.dart               # Structured JSON & ANSI Console Logger
│   │   │       └── support/
│   │   │           ├── facades.dart              # Zone-aware Facades (App, Auth, DB, Cache, Log, Config)
│   │   │           └── helpers.dart              # env(), config(), abort(), response(), now()
│   │   └── test/                                 # Comprehensive Framework Test Suite
│   │
│   └── dartisan_cli/                             # The "dartisan" Command-Line Interface
│       ├── pubspec.yaml
│       ├── bin/
│       │   └── dartisan.dart                     # CLI Executable Entrypoint
│       └── lib/
│           ├── dartisan_runner.dart              # CommandRunner setup
│           ├── commands/
│           │   ├── serve_command.dart            # File watcher + Hot-Reload / Fast-Restart server
│           │   ├── route_list_command.dart       # ASCII table of registered routes
│           │   ├── migrate_command.dart          # migrate, migrate:rollback, migrate:fresh, migrate:status
│           │   ├── db_seed_command.dart          # Database seeder runner
│           │   ├── key_generate_command.dart     # Generates APP_KEY (base64:...) in .env
│           │   └── make/
│           │       ├── make_controller_command.dart
│           │       ├── make_model_command.dart
│           │       ├── make_middleware_command.dart
│           │       ├── make_migration_command.dart
│           │       ├── make_request_command.dart
│           │       └── make_seeder_command.dart
│           └── stubs/                            # Code templates for make:* generators
│
└── apps/
    └── daravel_starter/                          # Reference Starter Application (Laravel 12 Structure)
        ├── pubspec.yaml
        ├── .env.example
        ├── bin/
        │   ├── server.dart                       # HTTP Server Entrypoint
        │   └── dartisan.dart                     # Project-bound CLI Entrypoint (loads project migrations/routes)
        ├── bootstrap/
        │   ├── app.dart                          # Fluent Application.configure()
        │   └── providers.dart                    # Registered ServiceProviders
        ├── config/
        │   ├── app_config.dart
        │   ├── database_config.dart
        │   └── auth_config.dart
        ├── database/
        │   ├── migrations/
        │   │   ├── m_0001_create_users_table.dart
        │   │   └── m_0002_create_personal_access_tokens_table.dart
        │   └── seeders/
        │       └── database_seeder.dart
        ├── lib/
        │   ├── app/
        │   │   ├── http/
        │   │   │   ├── controllers/
        │   │   │   │   └── auth_controller.dart
        │   │   │   ├── middleware/
        │   │   │   └── requests/
        │   │   │       └── register_request.dart
        │   │   ├── models/
        │   │   │   └── user.dart
        │   │   └── providers/
        │   │       └── app_service_provider.dart
        │   └── routes/
        │       └── api.dart
        └── test/
            └── feature/
                └── auth_flow_test.dart
```

---

## 3. WORKSPACE & PACKAGE CONFIGURATION

### Root `pubspec.yaml`
```yaml
name: daravel_workspace
publish_to: none
environment:
  sdk: ^3.6.0

workspace:
  - packages/daravel_core
  - packages/dartisan_cli
  - apps/daravel_starter
```

### Root `analysis_options.yaml`
```yaml
analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  errors:
    missing_required_param: error
    missing_return: error
    unused_import: warning

linter:
  rules:
    - always_declare_return_types
    - cancel_subscriptions
    - close_sinks
    - prefer_const_constructors
    - prefer_final_fields
    - prefer_final_locals
    - unawaited_futures
```

### Allowed External Dependencies (`packages/daravel_core/pubspec.yaml`)
Keep external dependencies minimal, stable, and 100% AOT-compatible:
- `crypto: ^3.0.6` (HMAC-SHA256, SHA-256 for JWT and Sanctum tokens)
- `cryptography: ^2.7.0` (Argon2id / PBKDF2 password hashing)
- `sqlite3: ^2.4.6` (Fast SQLite driver for local dev and in-memory testing)
- `postgres: ^3.4.0` (Production PostgreSQL driver with connection pooling)
- `mime: ^2.0.0` (MIME-type detection & Multipart boundary parsing)
- `path: ^1.9.0` (Cross-platform path manipulation)
- `meta: ^1.15.0` (Annotations `@protected`, `@immutable`)

### Allowed External Dependencies (`packages/dartisan_cli/pubspec.yaml`)
- `args: ^2.6.0` (Command-line argument parsing)
- `mason_logger: ^0.3.1` (Beautiful ANSI CLI spinners, tables, and prompts)
- `watcher: ^1.1.0` (File system watching for `dartisan serve --watch`)

---

## 4. DETAILED MODULE SPECIFICATIONS & CODE CONTRACTS

### MODULE 1: Foundation, IoC Container & Zone Context

#### 1.1 `Container` (`src/foundation/container.dart`)
The IoC Container manages three binding lifetimes:
- **Singleton (`singleton<T>`)**: Instantiated once per Isolate (e.g., `DatabaseManager`, `Router`, `Config`, `CacheManager`).
- **Transient (`bind<T>`)**: Instantiated fresh on every `make<T>()` call.
- **Request-Scoped (`scoped<T>`)**: Instantiated once per HTTP Request inside the active `Zone` (e.g., `Request`, `AuthContext`).

```dart
import 'dart:async';

typedef BindingFactory<T> = T Function(Container app);

class Container {
  final Map<Type, Object?> _instances = {};
  final Map<Type, BindingFactory<Object?>> _singletons = {};
  final Map<Type, BindingFactory<Object?>> _transients = {};
  final Map<Type, BindingFactory<Object?>> _scoped = {};

  static const Symbol zoneContainerKey = #_daravel_container;
  static const Symbol zoneScopeKey = #_daravel_request_scope;
  static const Symbol zoneTransactionKey = #_daravel_db_transaction;

  void instance<T Object extends>(T value) {
    _instances[T] = value;
  }

  void singleton<T Object extends>(BindingFactory<T> factory) {
    _singletons[T] = factory;
  }

  void bind<T Object extends>(BindingFactory<T> factory) {
    _transients[T] = factory;
  }

  void scoped<T Object extends>(BindingFactory<T> factory) {
    _scoped[T] = factory;
  }

  bool bound<T Object extends>() =>
      _instances.containsKey(T) ||
      _singletons.containsKey(T) ||
      _transients.containsKey(T) ||
      _scoped.containsKey(T);

  T make<T Object extends>() {
    // 1. Check Request-Scoped bindings in current Zone first
    final requestScope = Zone.current[zoneScopeKey] as Map<Type, Object?>?;
    if (requestScope != null) {
      if (requestScope.containsKey(T)) {
        return requestScope[T] as T;
      }
      if (_scoped.containsKey(T)) {
        final created = _scoped[T]!(this) as T;
        requestScope[T] = created;
        return created;
      }
    }

    // 2. Check resolved singletons
    if (_instances.containsKey(T)) {
      return _instances[T] as T;
    }

    // 3. Check lazy singletons
    if (_singletons.containsKey(T)) {
      final created = _singletons[T]!(this) as T;
      _instances[T] = created;
      return created;
    }

    // 4. Check transient bindings
    if (_transients.containsKey(T)) {
      return _transients[T]!(this) as T;
    }

    throw StateError('Service of type [$T] is not registered in the Daravel Container.');
  }

  /// Sets a request-scoped instance directly in the active Zone
  void setScopedInstance<T Object extends>(T instance) {
    final requestScope = Zone.current[zoneScopeKey] as Map<Type, Object?>?;
    if (requestScope == null) {
      throw StateError('Cannot set scoped instance [$T] outside of an active Request Zone.');
    }
    requestScope[T] = instance;
  }

  /// Executes [callback] inside an isolated Request Zone
  Future<R> runInRequestScope<R>(Future<R> Function() callback) {
    final scopedStore = <Type, Object?>{};
    return runZoned(
      callback,
      zoneValues: {
        zoneContainerKey: this,
        zoneScopeKey: scopedStore,
      },
    );
  }

  /// Retrieves the active Container from the current Zone
  static Container get current {
    final container = Zone.current[zoneContainerKey] as Container?;
    if (container == null) {
      throw StateError('No active Daravel Container found in the current Zone.');
    }
    return container;
  }
}
```

#### 1.2 `Application` & `ApplicationBuilder` (`src/foundation/application.dart`)
Mirrors Laravel 11/12's `Application::configure(basePath: ...)`:

```dart
class Application {
  final String basePath;
  final Container container = Container();
  final List<ServiceProvider> _providers = [];
  final List<Migration> _migrations = [];
  bool _booted = false;

  Application({required this.basePath});

  static ApplicationBuilder configure({String? basePath}) {
    return ApplicationBuilder(basePath: basePath ?? Directory.current.path);
  }

  Future<void> boot() async {
    if (_booted) return;
    for (final provider in _providers) {
      await provider.register(container);
    }
    for (final provider in _providers) {
      await provider.boot(container);
    }
    _booted = true;
  }

  /// Entrypoint for handling a single HTTP request (used by ServerEngine & TestClient)
  Future<Response> handleRequest(Request request);

  /// Starts the Multi-Isolate HTTP Server
  Future<void> serve({String? host, int? port, int? isolates});
}

class ApplicationBuilder {
  final String basePath;
  void Function(Router router)? _apiRoutes;
  void Function(Router router)? _webRoutes;
  String _apiPrefix = '/api';
  String? _healthPath = '/up';
  void Function(MiddlewareRegistry middleware)? _middlewareConfig;
  void Function(ExceptionHandler exceptions)? _exceptionConfig;
  final List<ServiceProvider> _providers = [];
  final List<Migration> _migrations = [];

  ApplicationBuilder({required this.basePath});

  ApplicationBuilder withRouting({
    void Function(Router router)? api,
    void Function(Router router)? web,
    String apiPrefix = '/api',
    String? health = '/up',
  });

  ApplicationBuilder withMiddleware(void Function(MiddlewareRegistry middleware) callback);
  ApplicationBuilder withExceptions(void Function(ExceptionHandler exceptions) callback);
  ApplicationBuilder withProviders(List<ServiceProvider> providers);
  ApplicationBuilder withMigrations(List<Migration> migrations);

  Application create();
}
```

---

### MODULE 2: HTTP Kernel, Request/Response & Middleware Pipeline

#### 2.1 `Request` (`src/http/request.dart`)
Must support both converting from `dart:io` `HttpRequest` AND constructing synthetic requests in unit/feature tests (`Request.fake(...)`) without opening a real socket:
- **Properties:**
  - `String method` (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`)
  - `Uri uri`
  - `String path`
  - `Map<String, String> headers` (case-insensitive lookup via `header(String name)`)
  - `Map<String, String> pathParams` (populated by Radix Router, accessed via `routeParam(String key)`)
  - `Map<String, String> queryParams`
  - `String clientIp`
- **Input Methods (Laravel-style):**
  - `T? input<T>(String key, [T? defaultValue])` — merges JSON body, form body, and query parameters. Supports dot-notation (`req.input<String>('user.email')`).
  - `Map<String, dynamic> all()`
  - `Map<String, dynamic> only(List<String> keys)`
  - `Map<String, dynamic> except(List<String> keys)`
  - `bool has(String key)` / `bool filled(String key)`
  - `UploadedFile? file(String key)`
  - `String? bearerToken()` — extracts token from `Authorization: Bearer <token>`.
- **Inline Validation Method:**
  - `Future<Map<String, dynamic>> validate(Map<String, List<ValidationRule>> rules, {Map<String, String>? messages})`

#### 2.2 `Response` (`src/http/response.dart`)
Immutable/chainable response object:
- `Response.json(Object? data, {int status = 200, Map<String, String>? headers})`
- `Response.created(Object? data, {Map<String, String>? headers})` (HTTP 201)
- `Response.noContent({Map<String, String>? headers})` (HTTP 204)
- `Response.text(String body, {int status = 200, Map<String, String>? headers})`
- `Response.html(String html, {int status = 200, Map<String, String>? headers})`
- `Response.redirect(String url, {int status = 302})`
- `Response.stream(Stream<List<int>> stream, {int status = 200, required String contentType})`
- `Response withHeader(String key, String value)`
- `Response withCookie(Cookie cookie)`

#### 2.3 `Middleware` & `MiddlewarePipeline` (`src/http/middleware/middleware.dart`)
```dart
typedef NextHandler = Future<Response> Function(Request request);

abstract class Middleware {
  const Middleware();
  Future<Response> handle(Request request, NextHandler next);
}

class FunctionalMiddleware extends Middleware {
  final Future<Response> Function(Request request, NextHandler next) _handler;
  const FunctionalMiddleware(this._handler);

  @override
  Future<Response> handle(Request request, NextHandler next) => _handler(request, next);
}
```
The `MiddlewarePipeline` executes global middlewares -> group middlewares -> route-specific middlewares in onion order, passing control to the route handler at the core.

---

### MODULE 3: Radix Tree Router & Fluent Route API

#### 3.1 Radix Tree Algorithm (`src/routing/radix_tree.dart`)
Do NOT iterate over a flat list of regular expressions. Implement a true **Segment-based Radix Trie** per HTTP method:
1. Static segments (`/users/profile`) take highest priority (Priority 1).
2. Parameter segments (`/users/:id` or `/users/{id}`) take second priority (Priority 2). Support both `:param` and `{param}` syntax so Laravel developers feel right at home.
3. Wildcard catch-all segments (`/files/*path`) take third priority (Priority 3).

#### 3.2 Fluent `Router` (`src/routing/router.dart`)
```dart
typedef RouteHandler = FutureOr<Response> Function(Request req);

class Router {
  RouteEntry get(String path, RouteHandler handler);
  RouteEntry post(String path, RouteHandler handler);
  RouteEntry put(String path, RouteHandler handler);
  RouteEntry patch(String path, RouteHandler handler);
  RouteEntry delete(String path, RouteHandler handler);
  RouteEntry any(String path, RouteHandler handler);

  /// Grouping with stackable prefix, middleware, and route name prefixes
  void group({
    String prefix = '',
    String namePrefix = '',
    List<Middleware> middleware = const [],
    required void Function(Router router) routes,
  });

  /// Registers index, show, store, update, destroy automatically
  void apiResource(String name, ResourceController controller, {List<Middleware> middleware = const []});

  /// Generates URL for a named route: route('users.show', {'id': 42})
  String urlFor(String name, [Map<String, Object?> params = const {}]);
}
```

#### 3.3 `RouteEntry` Chaining
```dart
router.get('/users/{id}', userController.show)
  .name('users.show')
  .middleware([AuthMiddleware()]);
```

---

### MODULE 4: Type-Safe Validation & FormRequests

#### 4.1 `ValidationRule` Contract (`src/validation/rules.dart`)
```dart
abstract class ValidationRule {
  const ValidationRule();
  String get name;

  /// Returns null if valid, or an error message string if invalid.
  FutureOr<String?> validate(
    String field,
    Object? value,
    Map<String, dynamic> data,
    Container container,
  );
}
```

#### 4.2 Built-In `Rule` Factory Methods
- `Rule.required()` — Fails if `null`, empty string `""`, empty list, or empty map.
- `Rule.nullable()` — Marker rule: if value is `null`, skip all subsequent rules for this field.
- `Rule.string()` / `Rule.integer()` / `Rule.numeric()` / `Rule.boolean()` / `Rule.list()` / `Rule.map()`
- `Rule.email()` — RFC-compliant email regex check.
- `Rule.min(num value)` — For numbers: `>= value`; for strings/lists: `.length >= value`.
- `Rule.max(num value)` — For numbers: `<= value`; for strings/lists: `.length <= value`.
- `Rule.between(num min, num max)`
- `Rule.confirmed([String? confirmationField])` — Checks matching `field_confirmation` (e.g., `password_confirmation`).
- `Rule.inList(List<Object> allowed)`
- `Rule.regex(RegExp pattern, {String? message})`
- `Rule.unique(String table, String column, {Object? ignoreId, String idColumn = 'id'})` — Queries the active `DatabaseManager` asynchronously to ensure uniqueness.
- `Rule.exists(String table, String column)` — Queries the active `DatabaseManager` asynchronously to verify foreign key existence.

#### 4.3 `ValidationException` & HTTP 422 Response
When validation fails, throw `ValidationException(Map<String, List<String>> errors)`. The global `ExceptionHandler` catches `ValidationException` and returns status `422`:
```json
{
  "message": "The given data was invalid.",
  "errors": {
    "email": ["The email field must be a valid email address."],
    "password": ["The password field must be at least 8 characters."]
  }
}
```

---

### MODULE 5: Database Layer (Drivers, Fluent Query Builder, ORM & Migrations)

#### 5.1 Unified `DatabaseDriver` & Zone-Aware Transactions (`src/database/drivers/database_driver.dart`)
```dart
abstract interface class QueryExecutor {
  SqlDialect get dialect;
  Future<List<Map<String, dynamic>>> query(String sql, [List<Object?> bindings = const []]);
  Future<int> execute(String sql, [List<Object?> bindings = const []]);
  Future<Object?> insertReturningId(String sql, List<Object?> bindings, {String idColumn = 'id'});
}

abstract interface class DatabaseDriver implements QueryExecutor {
  Future<void> connect();
  Future<void> close();
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) callback);
}
```

**Critical Architectural Requirement — Zone-Aware Transactions:**
When a user calls `await DB.transaction(() async { ... })`, `DatabaseManager` starts a driver transaction and runs the callback inside a child `Zone` carrying `Container.zoneTransactionKey: txExecutor`.
Whenever `DB.table('users')` or `User.create(...)` runs, `DatabaseManager.activeExecutor` checks `Zone.current[Container.zoneTransactionKey]` first! This means nested repository/model calls automatically participate in the active transaction without passing a `tx` parameter through every function signature.

#### 5.2 SQL Dialect Compiler (`src/database/query/grammar.dart`)
- **SQLite Dialect (`SqlDialect.sqlite`)**: Keeps `?` placeholders, uses `AUTOINCREMENT`, supports `:memory:` and file paths.
- **PostgreSQL Dialect (`SqlDialect.postgres`)**: Rewrites sequential `?` placeholders into `$1, $2, $3...` automatically, uses ` BIGSERIAL PRIMARY KEY`, appends `RETURNING id` on inserts.

#### 5.3 Fluent `QueryBuilder` (`src/database/query/query_builder.dart`)
Must support:
- `select(List<String> columns)`
- `where(String column, Object? operatorOrValue, [Object? value])` (if 2 args passed, operator defaults to `'='`)
- `orWhere(String column, Object? operatorOrValue, [Object? value])`
- `whereIn(String column, List<Object?> values)` / `whereNotIn(String column, List<Object?> values)`
- `whereNull(String column)` / `whereNotNull(String column)`
- `whereBetween(String column, Object min, Object max)`
- `join(String table, String first, String operator, String second)` / `leftJoin(...)`
- `orderBy(String column, [String direction = 'ASC'])` / `latest([String column = 'created_at'])`
- `limit(int count)` / `offset(int count)`
- `Future<List<Map<String, dynamic>>> get()`
- `Future<Map<String, dynamic>?> first()`
- `Future<Map<String, dynamic>> firstOrFail()`
- `Future<int> count()` / `Future<bool> exists()`
- `Future<PaginatedResult<Map<String, dynamic>>> paginate({int page = 1, int perPage = 15})`
- `Future<Object?> insertGetId(Map<String, dynamic> values, {String idColumn = 'id'})`
- `Future<Map<String, dynamic>> insertGetRecord(Map<String, dynamic> values, {String idColumn = 'id'})`
- `Future<int> update(Map<String, dynamic> values)`
- `Future<int> delete()`

#### 5.4 Type-Safe Active-Record Ergonomics (`Model<T>` & `ModelRepository<T>`)
```dart
abstract class Model<T Model<T extends>> {
  const Model();

  Object? get primaryKeyValue;
  Map<String, dynamic> toMap();

  /// List of attributes excluded when serializing to JSON (e.g., ['password'])
  List<String> get hidden => const [];

  Map<String, dynamic> toJson() {
    final map = Map<String, dynamic>.from(toMap());
    for (final key in hidden) {
      map.remove(key);
    }
    return map;
  }
}

class ModelRepository<T Model<T extends>> {
  final String table;
  final String primaryKey;
  final List<String> fillable;
  final bool timestamps;
  final T Function(Map<String, dynamic> row) fromRow;

  const ModelRepository({
    required this.table,
    required this.fromRow,
    this.primaryKey = 'id',
    this.fillable = const [],
    this.timestamps = true,
  });

  ModelQueryBuilder<T> query() => ModelQueryBuilder<T>(this, DB.table(table));
  ModelQueryBuilder<T> where(String column, Object? opOrVal, [Object? val]) =>
      query().where(column, opOrVal, val);

  Future<List<T>> all() => query().get();
  Future<T?> find(Object id) => query().where(primaryKey, id).first();
  Future<T> findOrFail(Object id) async {
    final model = await find(id);
    if (model == null) throw ModelNotFoundException(table, id);
    return model;
  }

  Future<T> create(Map<String, dynamic> attributes);
  Future<T> updateModel(Object id, Map<String, dynamic> attributes);
  Future<bool> destroy(Object id);
}
```

#### 5.5 Schema Builder & Migrations (`src/database/schema/`)
```dart
abstract class Migration {
  const Migration();
  String get name;
  Future<void> up(SchemaBuilder schema);
  Future<void> down(SchemaBuilder schema);
}
```
`Blueprint` methods:
- `table.id([String name = 'id'])`
- `table.string(String name, {int length = 255})`
- `table.text(String name)`
- `table.integer(String name)` / `table.bigInteger(String name)`
- `table.boolean(String name, {bool defaultValue = false})`
- `table.doublePrecision(String name)`
- `table.timestamp(String name)` / `table.timestamps()` (creates nullable `created_at` and `updated_at`)
- `table.foreignId(String name).constrained(String table, {String column = 'id', String onDelete = 'CASCADE'})`
- Column modifiers on returned `ColumnDefinition`: `.nullable()`, `.unique()`, `.defaultTo(Object value)`, `.index()`.

---

### MODULE 6: Authentication (Sanctum & JWT) & Security

#### 6.1 Password Hashing (`src/auth/hash.dart`)
Implement `Hash` facade using `package:cryptography` (PBKDF2-HMAC-SHA256 with random 16-byte salt and timing-safe comparison so it works natively in pure Dart across all OS targets without C-compiler FFI issues):
- `Future<String> Hash.make(String plainText)`
- `Future<bool> Hash.check(String plainText, String hashed)`

#### 6.2 Guards (`JwtGuard` & `SanctumGuard`)
1. **`SanctumGuard` (Default API Guard — Personal Access Tokens):**
   - Generates tokens formatted as `<token_id>|<40_char_random_secret>`.
   - Stores only the `sha256(secret)` in the `personal_access_tokens` table (`id`, `tokenable_type`, `tokenable_id`, `name`, `token`, `abilities`, `last_used_at`, `expires_at`, `created_at`, `updated_at`).
   - Supports token abilities (`Auth.tokenCan('posts:create')`).
2. **`JwtGuard` (Stateless Guard):**
   - Signs and verifies standard `HS256` JWT tokens using `APP_KEY` from `Config`, checking `exp`, `iat`, and `sub`.

---

### MODULE 7: Facades (`src/support/facades.dart`)

Provide clean static Facades that resolve services from `Container.current`:
- `App.make<T>()`
- `Config.get<T>(String key, [T? defaultValue])`
- `DB.table(String name)` / `DB.transaction<T>(...)` / `DB.rawQuery(...)`
- `Schema.create(...)` / `Schema.dropIfExists(...)`
- `Auth.user<T extends Authenticatable>()` / `Auth.id()` / `Auth.check()` / `Auth.guard([String? name])`
- `Cache.get<T>(String key)` / `Cache.put(String key, Object value, {Duration? ttl})` / `Cache.remember<T>(String key, Duration ttl, Future<T> Function() callback)`
- `Log.info(String message, [Map<String, dynamic>? context])` / `Log.error(...)` / `Log.warning(...)`
- `Events.dispatch<E extends Object>(E event)` / `Events.listen<E extends Object>(FutureOr<void> Function(E event) listener)`

---

### MODULE 8: `dartisan` CLI Specification (`packages/dartisan_cli`)

`dartisan` must work both as a global executable (`dartisan <command>`) and via project runner (`dart run bin/dartisan.dart <command>`):

| Command | Description |
| :--- | :--- |
| `dartisan serve [--host=0.0.0.0] [--port=8000] [--watch] [--isolates=N]` | Starts the Daravel server. With `--watch`, watches `lib/`, `bin/`, `bootstrap/`, `config/`, and `.env` and triggers sub-second hot-restart upon file changes. |
| `dartisan route:list` | Boots the application router and prints a formatted ASCII table showing `Method`, `URI`, `Name`, and `Middleware`. |
| `dartisan key:generate` | Generates a cryptographically secure 32-byte base64 key (`base64:...`) and writes/updates `APP_KEY` in `.env`. |
| `dartisan migrate [--step]` | Runs all pending migrations and records batch number in the `migrations` table. |
| `dartisan migrate:rollback [--step=1]` | Rolls back the last migration batch. |
| `dartisan migrate:fresh [--seed]` | Drops all tables, re-runs all migrations from scratch, and optionally runs `DatabaseSeeder`. |
| `dartisan migrate:status` | Displays a table of all migrations and whether they have `Ran` (with batch number) or are `Pending`. |
| `dartisan db:seed` | Executes registered database seeders. |
| `dartisan make:controller <Name> [--resource]` | Scaffolds a controller in `lib/app/http/controllers/`. |
| `dartisan make:model <Name> [-m] [-c]` | Scaffolds a `Model` + `ModelRepository` in `lib/app/models/` (optional migration `-m` and controller `-c`). |
| `dartisan make:migration <name>` | Scaffolds a timestamped migration class in `database/migrations/` and updates the migration registry. |
| `dartisan make:middleware <Name>` | Scaffolds a middleware class in `lib/app/http/middleware/`. |
| `dartisan make:request <Name>` | Scaffolds a `FormRequest` validation class in `lib/app/http/requests/`. |

---

## 5. TARGET DEVELOPER EXPERIENCE (END-STATE REFERENCE CODE)

The framework implementation MUST make the following user-land code in `apps/daravel_starter` compile and pass all tests seamlessly:

### 5.1 `bootstrap/app.dart`
```dart
import 'dart:io';
import 'package:daravel_core/daravel_core.dart';
import '../database/migrations/m_0001_create_users_table.dart';
import '../database/migrations/m_0002_create_personal_access_tokens_table.dart';
import '../lib/routes/api.dart';
import 'providers.dart';

Application createApp({String? basePath, Map<String, String>? envOverrides}) {
  return Application.configure(basePath: basePath ?? Directory.current.path)
      .withProviders(appProviders)
      .withMigrations([
        const CreateUsersTable(),
        const CreatePersonalAccessTokensTable(),
      ])
      .withRouting(
        api: registerApiRoutes,
        apiPrefix: '/api',
        health: '/up',
      )
      .withMiddleware((middleware) {
        middleware.use([
          const CorsMiddleware(),
          const TrimStringsMiddleware(),
        ]);
        middleware.alias({
          'auth': const AuthenticateMiddleware(),
          'throttle': ThrottleMiddleware(maxAttempts: 60, decay: const Duration(minutes: 1)),
        });
      })
      .withExceptions((exceptions) {
        exceptions.render<ModelNotFoundException>((e, req) {
          return Response.json({
            'message': 'Resource [${e.table}] with ID [${e.id}] not found.',
          }, status: 404);
        });
      })
      .create();
}
```

### 5.2 `lib/routes/api.dart`
```dart
import 'package:daravel_core/daravel_core.dart';
import '../app/http/controllers/auth_controller.dart';

void registerApiRoutes(Router router) {
  final authController = AuthController();

  router.group(prefix: '/auth', routes: (r) {
    r.post('/register', authController.register).name('auth.register');
    r.post('/login', authController.login).name('auth.login');

    r.group(middleware: [const AuthenticateMiddleware()], routes: (protected) {
      protected.get('/me', authController.me).name('auth.me');
      protected.post('/logout', authController.logout).name('auth.logout');
    });
  });
}
```

### 5.3 `lib/app/models/user.dart`
```dart
import 'package:daravel_core/daravel_core.dart';

class User extends Model<User> implements Authenticatable {
  final int id;
  final String name;
  final String email;
  final String passwordHash;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.passwordHash,
    this.createdAt,
    this.updatedAt,
  });

  @override
  Object get primaryKeyValue => id;

  @override
  Object get authIdentifier => id;

  @override
  String get authPassword => passwordHash;

  @override
  List<String> get hidden => const ['password_hash'];

  @override
  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'email': email,
        'password_hash': passwordHash,
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt?.toIso8601String(),
      };

  static final repo = ModelRepository<User>(
    table: 'users',
    fillable: const ['name', 'email', 'password_hash'],
    fromRow: (row) => User(
      id: (row['id'] as num).toInt(),
      name: row['name'] as String,
      email: row['email'] as String,
      passwordHash: row['password_hash'] as String,
      createdAt: row['created_at'] != null ? DateTime.tryParse(row['created_at'].toString()) : null,
      updatedAt: row['updated_at'] != null ? DateTime.tryParse(row['updated_at'].toString()) : null,
    ),
  );

  static ModelQueryBuilder<User> query() => repo.query();
  static Future<User?> find(int id) => repo.find(id);
  static Future<User> findOrFail(int id) => repo.findOrFail(id);
  static Future<User> create(Map<String, dynamic> data) => repo.create(data);
}
```

### 5.4 `lib/app/http/controllers/auth_controller.dart`
```dart
import 'package:daravel_core/daravel_core.dart';
import '../../models/user.dart';

class AuthController extends Controller {
  Future<Response> register(Request req) async {
    final data = await req.validate({
      'name': [Rule.required(), Rule.string(), Rule.min(2), Rule.max(100)],
      'email': [Rule.required(), Rule.email(), Rule.unique('users', 'email')],
      'password': [Rule.required(), Rule.string(), Rule.min(8), Rule.confirmed()],
    });

    final user = await DB.transaction(() async {
      return User.create({
        'name': data['name'],
        'email': data['email'],
        'password_hash': await Hash.make(data['password'] as String),
      });
    });

    final token = await Auth.issueToken(user, name: 'default_api_token');

    return Response.created({
      'message': 'Registration successful.',
      'user': user.toJson(),
      'token': token.plainTextToken,
    });
  }

  Future<Response> login(Request req) async {
    final data = await req.validate({
      'email': [Rule.required(), Rule.email()],
      'password': [Rule.required(), Rule.string()],
    });

    final user = await User.query().where('email', data['email']).first();
    if (user == null || !await Hash.check(data['password'] as String, user.passwordHash)) {
      return Response.json({
        'message': 'Invalid credentials.',
      }, status: 401);
    }

    final token = await Auth.issueToken(user, name: 'login_token');

    return Response.json({
      'user': user.toJson(),
      'token': token.plainTextToken,
    });
  }

  Future<Response> me(Request req) async {
    final user = Auth.user<User>();
    return Response.json({'user': user.toJson()});
  }

  Future<Response> logout(Request req) async {
    await Auth.revokeCurrentToken();
    return Response.json({'message': 'Logged out successfully.'});
  }
}
```

---

## 6. PHASED EXECUTION PLAN FOR CLAUDE

Execute this blueprint in **6 sequential phases**. At the end of each phase, run `dart analyze` and `dart test` to guarantee zero errors before advancing to the next phase.

### PHASE 1: Workspace Setup, Foundation, Container & Zone Context
- Create root `pubspec.yaml`, `analysis_options.yaml`, and `packages/daravel_core/pubspec.yaml`.
- Implement `Env`, `Config`, `Container` (with `runInRequestScope`), `ServiceProvider`, `Logger`, `EventDispatcher`, and `CacheManager` (`MemoryStore` + `RateLimiter`).
- Write `packages/daravel_core/test/foundation_test.dart` verifying concurrent `runInRequestScope` calls never leak scoped instances across overlapping asynchronous requests.

### PHASE 2: HTTP Layer, Radix Tree Router, Middleware & Exception Handler
- Implement `Request`, `Response`, `UploadedFile`, `Middleware`, `MiddlewarePipeline`, `CorsMiddleware`, `ThrottleMiddleware`, and `TrimStringsMiddleware`.
- Implement `RadixTree`, `Router` (`get`, `post`, `put`, `patch`, `delete`, `group`, `apiResource`), `RouteEntry`, `ExceptionHandler`, and `ServerEngine` (multi-isolate).
- Write `packages/daravel_core/test/routing_http_test.dart` testing Radix Tree priority (static vs `:param` vs `*wildcard`), named route URL generation, middleware onion execution order, and rate limiting.

### PHASE 3: Database Engine, Fluent Query Builder, ORM & Schema Migrations
- Implement `SqlDialect`, `Grammar` (`?` vs `$1` binding compiler), `DatabaseDriver`, `SqliteDriver`, `PostgresDriver`, and `DatabaseManager` (with Zone-aware nested transaction propagation).
- Implement `QueryBuilder`, `Paginator`, `Model<T>`, `ModelRepository<T>`, `ModelQueryBuilder<T>`.
- Implement `Blueprint`, `SchemaBuilder`, `Migration`, and `Migrator` (`up`, `rollback`, `fresh`, `status`).
- Write `packages/daravel_core/test/database_orm_test.dart` using in-memory SQLite (`:memory:`) to test migrations, CRUD, parameterized SQL injection prevention, pagination, and automatic transaction rollback on exception.

### PHASE 4: Validation Engine, Hashing & Authentication (Sanctum + JWT)
- Implement `ValidationRule`, `Rule` (all sync & async database rules `unique` and `exists`), `Validator`, and `FormRequest`.
- Implement `Hash`, `Authenticatable`, `AuthManager`, `SanctumGuard` (`personal_access_tokens` SHA-256 verification & abilities), `JwtGuard` (HMAC-SHA256), `AuthenticateMiddleware`, and `Application` / `ApplicationBuilder` + Facades (`src/support/facades.dart`).
- Write `packages/daravel_core/test/auth_validation_test.dart`.

### PHASE 5: `dartisan` CLI Package
- Create `packages/dartisan_cli` with `CommandRunner`.
- Implement `serve` (with file watcher), `route:list`, `key:generate`, `migrate`, `migrate:rollback`, `migrate:fresh`, `migrate:status`, `db:seed`, and `make:*` (`make:controller`, `make:model`, `make:migration`, `make:middleware`, `make:request`).
- Write CLI tests in `packages/dartisan_cli/test/cli_test.dart`.

### PHASE 6: `apps/daravel_starter` Reference Application & AOT Binary Verification
- Build the complete `apps/daravel_starter` project using `bootstrap/app.dart`, `User` model, `AuthController`, and migrations.
- Write end-to-end feature tests in `apps/daravel_starter/test/feature/auth_flow_test.dart` covering registration, validation errors (422), duplicate email rejection, login, protected `/api/auth/me` route (200 with token, 401 without token), and token revocation (`/api/auth/logout`).
- Compile `apps/daravel_starter/bin/server.dart` using `dart compile exe` to prove 100% AOT native binary compatibility.