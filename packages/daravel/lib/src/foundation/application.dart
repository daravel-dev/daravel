import 'dart:async';
import 'dart:io';

import '../database/database_config.dart';
import '../database/database_manager.dart';
import '../database/schema/migration.dart';
import '../http/exception_handler.dart';
import '../http/kernel.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../http/server_engine.dart';
import '../logging/logger.dart';
import '../routing/router.dart';
import 'config.dart';
import 'container.dart';
import 'env.dart';
import 'service_provider.dart';

final class _RoutingConfig {
  const _RoutingConfig({
    this.api,
    this.web,
    this.apiPrefix = '/api',
    this.health = '/up',
    this.then = const <void Function(Router)>[],
  });

  final void Function(Router router)? api;
  final void Function(Router router)? web;
  final String apiPrefix;
  final String? health;
  final List<void Function(Router router)> then;
}

/// The application: owns the container, configuration, router and kernel
/// (BLUEPRINT_V2 §7.1.2, §5.3).
final class Application {
  Application._(this._builder)
    : basePath = _builder.basePath,
      container = Container(),
      router = Router(),
      middleware = MiddlewareRegistry(),
      exceptions = ExceptionHandler();

  /// Starts fluent configuration (`Application.configure(basePath: ...)`).
  static ApplicationBuilder configure({String? basePath}) =>
      ApplicationBuilder(basePath: basePath ?? Directory.current.path);

  final ApplicationBuilder _builder;

  /// Project root used to locate `.env`, `database/`, `storage/`.
  final String basePath;

  final Container container;
  final Router router;
  final MiddlewareRegistry middleware;
  final ExceptionHandler exceptions;

  late final Env env;
  late final ConfigRepository config;
  late final Logger logger;
  late final HttpKernel kernel;

  Future<void>? _booting;
  bool _booted = false;
  bool _draining = false;
  ServerEngine? _engine;

  /// Whether [boot] has completed.
  bool get booted => _booted;

  /// Whether the server is shutting down (health endpoint answers 503).
  bool get draining => _draining;

  /// The running server engine, if any.
  ServerEngine? get engine => _engine;

  /// Boots the application exactly once (safe to call concurrently).
  Future<void> boot() => _booting ??= _boot();

  Future<void> _boot() async {
    env = await Env.load(basePath: basePath, overrides: _builder._envOverrides);
    logger = Logger(minimumLevel: _builder._logLevel ?? LogLevel.debug);
    exceptions.logger = logger;

    config = ConfigRepository()
      ..register(AppConfig.fromEnv(env))
      ..register(DatabaseConfig.fromEnv(env, basePath: basePath));
    for (final factory in _builder._configFactories) {
      config.register(factory(env));
    }
    final appConfig = config.section<AppConfig>();
    exceptions.debug = appConfig.debug;
    if (appConfig.isProduction && appConfig.debug) {
      logger.warning(
        'APP_DEBUG=true while APP_ENV=production: error responses will leak '
        'stack traces. Disable debug mode in production.',
      );
    }

    container
      ..instance<Application>(this)
      ..instance<Env>(env)
      ..instance<ConfigRepository>(config)
      ..instance<Logger>(logger)
      ..instance<Router>(router)
      ..instance<MiddlewareRegistry>(middleware)
      ..instance<ExceptionHandler>(exceptions)
      ..singleton<DatabaseManager>(
        (c) => DatabaseManager(
          c.make<ConfigRepository>().section<DatabaseConfig>(),
          logger: c.make<Logger>(),
        ),
      )
      ..singleton<Migrator>(
        (c) => Migrator(c.make<DatabaseManager>(), _builder._migrations),
      );

    _builder._middlewareConfig?.call(middleware);
    _builder._exceptionsConfig?.call(exceptions);

    for (final provider in _builder._providers) {
      await provider.register(container);
    }
    for (final provider in _builder._providers) {
      await provider.boot(container);
    }

    _registerRoutes();
    router.compile(middleware);
    kernel = HttpKernel(
      router: router,
      middleware: middleware,
      exceptions: exceptions,
    );
    container.instance<HttpKernel>(kernel);

    config.freeze();
    Container.setRoot(container);
    _booted = true;
  }

  void _registerRoutes() {
    final routing = _builder._routing;
    if (routing == null) {
      return;
    }
    final health = routing.health;
    if (health != null) {
      router.get(health, _health);
    }
    final api = routing.api;
    if (api != null) {
      router.group(api, prefix: routing.apiPrefix);
    }
    final web = routing.web;
    if (web != null) {
      router.group(web);
    }
    for (final extra in routing.then) {
      extra(router);
    }
  }

  Object? _health(Request request) {
    if (_draining) {
      return Response.json(const <String, Object?>{
        'status': 'draining',
      }, status: 503);
    }
    return <String, Object?>{
      'status': 'ok',
      'app': config.section<AppConfig>().name,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// Handles one request inside a fresh request scope (used by the server
  /// engine and the test client).
  Future<Response> handle(Request request) async {
    await boot();
    return container.runScoped<Response>(
      'request',
      (_) => kernel.handle(request),
    );
  }

  /// Runs [body] inside a scope named [scope] with this application's
  /// container active (commands, tests, scripts).
  Future<R> run<R>(
    FutureOr<R> Function() body, {
    String scope = 'command',
  }) async {
    await boot();
    return container.runScoped<R>(scope, (_) => body());
  }

  /// Boots, serves HTTP until the engine stops, then releases resources.
  Future<void> serve({ServeOptions? options}) async {
    await boot();
    final engine = ServerEngine(
      this,
      options ?? ServeOptions.fromEnv(env),
      kernel: kernel,
      logger: logger,
    );
    _engine = engine;
    await engine.start();
    await engine.done;
    _engine = null;
    await _closeResources();
  }

  /// Stops the server (if running) and releases resources.
  Future<void> shutdown() async {
    final engine = _engine;
    if (engine != null) {
      await engine.stop();
    } else {
      await _closeResources();
    }
  }

  /// Marks the application as draining; `/up` answers `503` from now on.
  void markDraining() => _draining = true;

  Future<void> _closeResources() async {
    final db = container.resolved<DatabaseManager>();
    if (db != null) {
      await db.closeAll();
    }
    if (Container.rootOrNull == container) {
      Container.setRoot(null);
    }
  }
}

/// Fluent builder mirroring Laravel's `Application::configure()`.
final class ApplicationBuilder {
  ApplicationBuilder({required this.basePath});

  final String basePath;

  Map<String, String> _envOverrides = const <String, String>{};
  _RoutingConfig? _routing;
  void Function(MiddlewareRegistry middleware)? _middlewareConfig;
  void Function(ExceptionHandler exceptions)? _exceptionsConfig;
  final List<ServiceProvider> _providers = <ServiceProvider>[];
  final List<Migration> _migrations = <Migration>[];
  final List<ConfigSection Function(Env env)> _configFactories =
      <ConfigSection Function(Env env)>[];
  LogLevel? _logLevel;

  /// Environment overrides with the highest precedence (tests, CLI flags).
  ApplicationBuilder withEnv(Map<String, String> overrides) {
    _envOverrides = <String, String>{..._envOverrides, ...overrides};
    return this;
  }

  /// Registers route callbacks. [api] routes are grouped under [apiPrefix];
  /// [health] registers the liveness endpoint (`null` disables it).
  ApplicationBuilder withRouting({
    void Function(Router router)? api,
    void Function(Router router)? web,
    String apiPrefix = '/api',
    String? health = '/up',
    List<void Function(Router router)> then = const <void Function(Router)>[],
  }) {
    _routing = _RoutingConfig(
      api: api,
      web: web,
      apiPrefix: apiPrefix,
      health: health,
      then: then,
    );
    return this;
  }

  ApplicationBuilder withMiddleware(
    void Function(MiddlewareRegistry middleware) configure,
  ) {
    _middlewareConfig = configure;
    return this;
  }

  ApplicationBuilder withExceptions(
    void Function(ExceptionHandler exceptions) configure,
  ) {
    _exceptionsConfig = configure;
    return this;
  }

  ApplicationBuilder withProviders(List<ServiceProvider> providers) {
    _providers.addAll(providers);
    return this;
  }

  ApplicationBuilder withMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  /// Registers an additional typed configuration section.
  ApplicationBuilder withConfig<T extends ConfigSection>(
    T Function(Env env) factory,
  ) {
    _configFactories.add(factory);
    return this;
  }

  /// Minimum log level (defaults to `debug`).
  ApplicationBuilder withLogLevel(LogLevel level) {
    _logLevel = level;
    return this;
  }

  /// Creates the (not yet booted) application.
  Application create() => Application._(this);
}
