import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'clock.dart';

import '../auth/auth_manager.dart';
import '../auth/authorization.dart';
import '../auth/contracts.dart';
import '../auth/encryption.dart';
import '../auth/hashing.dart';
import '../cache/cache.dart';
import '../database/database_config.dart';
import '../database/database_manager.dart';
import '../database/schema/migration.dart';
import '../database/seeding/seeder.dart';
import '../observability/health.dart';
import '../observability/metrics.dart';
import '../storage/storage.dart';
import '../events/events.dart';
import '../http/exception_handler.dart';
import '../http/headers.dart';
import '../http/middleware/validate_signature.dart';
import '../http/kernel.dart';
import '../http/middleware.dart';
import '../http/rate_limiter.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../http/server_engine.dart';
import '../logging/logger.dart';
import '../queue/drivers.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';
import '../routing/router.dart';
import '../routing/url_signer.dart';
import '../schedule/schedule.dart';
import '../server/coordinator.dart';
import '../server/supervisor.dart';
import 'config.dart';
import 'config_validator.dart';
import 'container.dart';
import 'env.dart';
import 'exceptions.dart';
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

  /// Channel to the process coordinator (`process`-scope rate limits, locks,
  /// cache). Set by the [Supervisor] before boot; in-process otherwise.
  CoordinatorChannel? coordinator;

  Timer? _metricsTimer;

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
    final loggingConfig = LoggingConfig.fromEnv(env);
    logger = Logger.fromConfig(
      loggingConfig,
      basePath: basePath,
      minimumLevel: _builder._logLevel,
    );
    exceptions.logger = logger;

    config = ConfigRepository()
      ..register(AppConfig.fromEnv(env))
      ..register(DatabaseConfig.fromEnv(env, basePath: basePath))
      ..register(HashConfig.fromEnv(env))
      ..register(AuthConfig.fromEnv(env))
      ..register(CacheConfig.fromEnv(env))
      ..register(QueueConfig.fromEnv(env))
      ..register(loggingConfig)
      ..register(StorageConfig.fromEnv(env))
      ..register(MetricsConfig.fromEnv(env));
    for (final factory in _builder._configFactories) {
      config.register(factory(env));
    }
    final appConfig = config.section<AppConfig>();
    exceptions.debug = appConfig.debug;

    final validator = ConfigValidator(
      extraChecks: [DatabaseConfig.check, ..._builder._configChecks],
    );
    for (final issue in validator.validateOrThrow(env, config)) {
      logger.warning('Config: ${issue.message}');
    }

    final auth = AuthManager(
      config.section<AuthConfig>(),
      appKey: env.maybeString('APP_KEY'),
    );
    final gate = AuthorizationGate(userResolver: () => _currentUser(auth));
    final channel =
        coordinator ?? LocalCoordinatorChannel(createStandardCoordinator());
    final events = EventDispatcher();
    final metrics = AppMetrics(MetricsRegistry(), channel: channel);
    events
      ..listen<JobProcessed>((_) => metrics.jobs.inc({'status': 'processed'}))
      ..listen<JobExceptionOccurred>(
        (e) =>
            metrics.jobs.inc({'status': e.willRetry ? 'released' : 'errored'}),
      )
      ..listen<JobFailed>((_) => metrics.jobs.inc({'status': 'failed'}));
    final jobs = JobRegistry(_builder._jobs);
    final schedule = Schedule();
    final rateLimiter = RateLimiter(
      store: ProcessRateLimitStore(
        channel,
        onError: (error) => logger.warning('Rate limiter fail-open: $error'),
      ),
    );
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
      )
      ..instance<SeederRegistry>(SeederRegistry(_builder._seeders))
      ..singleton<HashManager>(
        (c) => HashManager(c.make<ConfigRepository>().section<HashConfig>()),
      )
      ..singleton<Encrypter>((c) => _encrypter(c.make<Env>()))
      ..instance<RateLimiter>(rateLimiter)
      ..instance<AuthorizationGate>(gate)
      ..instance<AuthManager>(auth)
      ..instance<CoordinatorChannel>(channel)
      ..instance<EventDispatcher>(events)
      ..instance<AppMetrics>(metrics)
      ..singleton<StorageManager>(
        (c) => StorageManager(
          c.make<ConfigRepository>().section<StorageConfig>(),
          basePath: basePath,
        ).withDefaultDisks(),
      )
      ..instance<JobRegistry>(jobs)
      ..instance<Schedule>(schedule)
      ..singleton<QueueManager>((c) => _buildQueue(c, events, jobs))
      ..singleton<CacheManager>(
        (c) => CacheManager.fromConfig(
          c.make<ConfigRepository>().section<CacheConfig>(),
          basePath: basePath,
          database: () => c.make<DatabaseManager>(),
          channel: channel,
        ),
      );

    middleware
      ..aliasFactory('auth', AuthenticateMiddleware.new)
      ..aliasFactory('can', AuthorizeMiddleware.fromParams)
      ..aliasFactory(
        'throttle',
        (params) => ThrottleMiddleware.fromParams(
          params,
          limiter: rateLimiter,
          userKeyResolver: (_) => _currentUserId(auth),
        ),
      );

    _builder._middlewareConfig?.call(middleware);
    final metricsConfig = config.section<MetricsConfig>();
    if (metricsConfig.enabled) {
      middleware.prepend(MetricsMiddleware(metrics));
      _metricsTimer = metrics.startPublishing();
    }
    _builder._exceptionsConfig?.call(exceptions);

    for (final provider in _builder._providers) {
      await provider.register(container);
    }
    for (final provider in _builder._providers) {
      if (provider is DeferredServiceProvider) {
        continue;
      }
      await provider.boot(container);
    }

    _builder._authConfig?.call(auth);
    _builder._eventsConfig?.call(events);
    _builder._jobsConfig?.call(jobs);
    _builder._scheduleConfig?.call(schedule);
    events.afterCommitHook = (callback) =>
        container.make<DatabaseManager>().afterCommit(callback);
    events.queuePusher = (Job job) => container.make<QueueManager>().push(job);
    _builder._policiesConfig?.call(gate);
    _builder._rateLimitsConfig?.call(rateLimiter);

    router.baseUrl = appConfig.url;
    final appKey = env.maybeString('APP_KEY');
    if (appKey != null && appKey.isNotEmpty) {
      final signer = UrlSigner.fromAppKey(appKey);
      router.signer = signer;
      middleware.alias('signed', ValidateSignatureMiddleware(signer));
    }
    _registerRoutes();
    router.compile(middleware);
    kernel = HttpKernel(
      router: router,
      middleware: middleware,
      exceptions: exceptions,
      logger: logger,
    );
    container.instance<HttpKernel>(kernel);

    config.freeze();
    Container.setRoot(container);
    _booted = true;
  }

  QueueManager _buildQueue(
    Container c,
    EventDispatcher events,
    JobRegistry jobs,
  ) {
    final queueConfig = c.make<ConfigRepository>().section<QueueConfig>();
    final db = c.make<DatabaseManager>();
    final cache = c.make<CacheManager>();
    final failed = queueConfig.defaultConnection == 'database'
        ? DatabaseFailedJobProvider(db, table: queueConfig.failedTable)
        : MemoryFailedJobProvider();
    final lockStore = cache.store(queueConfig.uniqueLockStore);
    late final QueueManager manager;
    final processor = JobProcessor(
      registry: jobs,
      events: events,
      failedJobs: failed,
      container: c,
      logger: logger,
      uniqueLockRelease: (key) => manager.releaseUniqueLock(key),
    );
    manager =
        QueueManager(
            config: queueConfig,
            registry: jobs,
            events: events,
            container: c,
            processor: processor,
            database: db,
            lockStore: lockStore,
            logger: logger,
          )
          ..extend('sync', SyncQueue.new)
          ..extend('memory', MemoryQueue.new)
          ..extend(
            'database',
            () => DatabaseQueue(
              db,
              table: queueConfig.table,
              retryAfter: queueConfig.retryAfter,
            ),
          );
    return manager;
  }

  /// A scheduler over the registered [Schedule] (`schedule:run/work`).
  Scheduler scheduler({ScheduleCommandRunner? commandRunner}) => Scheduler(
    container.make<Schedule>(),
    environment: config.section<AppConfig>().env,
    events: container.make<EventDispatcher>(),
    queue: container.make<QueueManager>(),
    lockStore: container.make<CacheManager>().store(
      config.section<QueueConfig>().uniqueLockStore,
    ),
    commandRunner: commandRunner,
    logger: logger,
  );

  static Future<Authenticatable?> _currentUser(AuthManager auth) async {
    try {
      return await auth.user<Authenticatable>();
    } on StateError {
      return null;
    }
  }

  static Future<Object?> _currentUserId(AuthManager auth) async {
    try {
      return await auth.id();
    } on StateError {
      return null;
    }
  }

  static Encrypter _encrypter(Env env) {
    final key = env.maybeString('APP_KEY');
    if (key == null || key.isEmpty) {
      throw const ConfigException(
        'APP_KEY is not set; Crypt needs it. Run `dartisan key:generate`.',
      );
    }
    return Encrypter.fromAppKey(
      key,
      previousKeys: env.list('APP_PREVIOUS_KEYS'),
    );
  }

  void _registerRoutes() {
    final routing = _builder._routing;
    if (routing == null) {
      return;
    }
    final health = routing.health;
    if (health != null) {
      router.get(health, _health);
      router.get('${health == '/' ? '' : health}/ready', _ready);
    }
    final metricsConfig = config.section<MetricsConfig>();
    if (metricsConfig.enabled) {
      router.get(metricsConfig.path, _metrics);
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
      'timestamp': Clock.now().toUtc().toIso8601String(),
    };
  }

  /// Readiness: runs the health checks (database, cache and any added via
  /// [ApplicationBuilder.withHealthChecks]).
  Future<Object?> _ready(Request request) async {
    if (_draining) {
      return Response.json(const <String, Object?>{
        'status': 'draining',
      }, status: 503);
    }
    final result = await healthChecker.run();
    return Response.json(result.body, status: result.healthy ? 200 : 503);
  }

  /// The configured readiness checks.
  HealthChecker get healthChecker => HealthChecker(<HealthCheck>[
    if (_builder._defaultHealthChecks) ...[
      DatabaseHealthCheck(() => container.make<DatabaseManager>()),
      CacheHealthCheck(() => container.make<CacheManager>()),
    ],
    ..._builder._healthChecks,
  ]);

  Future<Object?> _metrics(Request request) async {
    final token = config.section<MetricsConfig>().token;
    if (token != null) {
      final header = request.headers['authorization'] ?? '';
      if (!constantTimeEquals(header, 'Bearer $token')) {
        return Response.json(const <String, Object?>{
          'message': 'Unauthenticated.',
        }, status: 401);
      }
    }
    final text = await container.make<AppMetrics>().render();
    return Response(
      headers: Headers(<String, Object>{
        'content-type': 'text/plain; version=0.0.4; charset=utf-8',
      }),
      body: BytesBody(utf8.encode(text)),
    );
  }

  /// Handles one request inside a fresh request scope (used by the server
  /// engine and the test client).
  /// [prepare] runs inside the request scope before the kernel (the test
  /// client uses it for `actingAs`).
  Future<Response> handle(
    Request request, {
    FutureOr<void> Function()? prepare,
  }) async {
    await boot();
    return container.runScoped<Response>('request', (scope) async {
      scope.put<Request>(request);
      await prepare?.call();
      return kernel.handle(request);
    });
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

  /// Serves with [factory]: in-process when `isolates <= 1`, otherwise a
  /// [Supervisor] spawns `isolates` workers that each build their own
  /// application. Returns the process exit code.
  static Future<int> serveWith(
    ApplicationFactory factory, {
    String? host,
    int? port,
    int? isolates,
  }) async {
    final probe = factory();
    await probe.boot();
    final options = ServeOptions.fromEnv(
      probe.env,
      host: host,
      port: port,
      isolates: isolates,
    );
    if (options.isolates <= 1) {
      await probe.serve(options: options);
      return 0;
    }
    probe._ensureServeable(options);
    final logger = probe.logger;
    await probe.shutdown();
    return Supervisor(factory, options, logger: logger).run();
  }

  /// Boots, serves HTTP until the engine stops, then releases resources.
  /// [onStarted] fires once the socket is bound (used by workers to report
  /// readiness).
  Future<void> serve({
    ServeOptions? options,
    void Function(ServerEngine engine)? onStarted,
  }) async {
    await boot();
    final resolved = options ?? ServeOptions.fromEnv(env);
    _ensureServeable(resolved);
    final engine = ServerEngine(this, resolved, kernel: kernel, logger: logger);
    _engine = engine;
    await engine.start();
    onStarted?.call(engine);
    await engine.done;
    _engine = null;
    await _closeResources();
  }

  void _ensureServeable(ServeOptions resolved) {
    final db = config.section<DatabaseConfig>();
    final connection = db.connections[db.defaultConnection];
    if (resolved.isolates > 1 &&
        connection?.driver == 'sqlite' &&
        connection?.database == ':memory:') {
      throw ConfigException(
        'An in-memory SQLite database cannot be shared across '
        '${resolved.isolates} isolates (each isolate would get its own empty '
        'database). Use a file database or run with isolates: 1.',
      );
    }
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
    _metricsTimer?.cancel();
    _metricsTimer = null;
    final db = container.resolved<DatabaseManager>();
    if (db != null) {
      await db.closeAll();
    }
    if (Container.rootOrNull == container) {
      Container.setRoot(null);
    }
    await logger.close();
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
  void Function(AuthManager auth)? _authConfig;
  void Function(AuthorizationGate gate)? _policiesConfig;
  void Function(RateLimiter limiter)? _rateLimitsConfig;
  void Function(EventDispatcher events)? _eventsConfig;
  void Function(JobRegistry jobs)? _jobsConfig;
  void Function(Schedule schedule)? _scheduleConfig;
  final List<JobDefinition> _jobs = <JobDefinition>[];
  final List<HealthCheck> _healthChecks = <HealthCheck>[];
  bool _defaultHealthChecks = true;
  final List<ServiceProvider> _providers = <ServiceProvider>[];
  final List<Migration> _migrations = <Migration>[];
  final List<Seeder> _seeders = <Seeder>[];

  /// Registers database seeders; the first one is the root seeder.
  ApplicationBuilder withSeeders(List<Seeder> seeders) {
    _seeders.addAll(seeders);
    return this;
  }

  /// Registers guards and user providers (`config/auth.php`).
  ApplicationBuilder withAuth(void Function(AuthManager auth) configure) {
    _authConfig = configure;
    return this;
  }

  /// Registers gates and policies (`Gate::define`, `Gate::policy`).
  ApplicationBuilder withPolicies(
    void Function(AuthorizationGate gate) configure,
  ) {
    _policiesConfig = configure;
    return this;
  }

  /// Registers event listeners and subscribers (`EventServiceProvider`).
  ApplicationBuilder withEvents(
    void Function(EventDispatcher events) configure,
  ) {
    _eventsConfig = configure;
    return this;
  }

  /// Registers job definitions (`bootstrap/jobs.dart`); [configure] may add
  /// more, e.g. queued listeners.
  ApplicationBuilder withJobs(
    List<JobDefinition> jobs, {
    void Function(JobRegistry jobs)? configure,
  }) {
    _jobs.addAll(jobs);
    _jobsConfig = configure;
    return this;
  }

  /// Adds readiness checks to `/up/ready`; [defaults] keeps the database
  /// and cache checks.
  ApplicationBuilder withHealthChecks(
    List<HealthCheck> checks, {
    bool defaults = true,
  }) {
    _healthChecks.addAll(checks);
    _defaultHealthChecks = defaults;
    return this;
  }

  /// Declares scheduled tasks (`routes/console.dart`).
  ApplicationBuilder withSchedule(void Function(Schedule schedule) define) {
    _scheduleConfig = define;
    return this;
  }

  /// Registers named rate limiters (`RateLimiter::for`).
  ApplicationBuilder withRateLimits(
    void Function(RateLimiter limiter) configure,
  ) {
    _rateLimitsConfig = configure;
    return this;
  }

  final List<ConfigSection Function(Env env)> _configFactories =
      <ConfigSection Function(Env env)>[];
  final List<ConfigCheck> _configChecks = <ConfigCheck>[];
  LogLevel? _logLevel;

  /// Adds a configuration check run at boot (errors abort the boot).
  ApplicationBuilder withConfigCheck(ConfigCheck check) {
    _configChecks.add(check);
    return this;
  }

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
