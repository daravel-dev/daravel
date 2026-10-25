import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'clock.dart';

import '../auth/auth_manager.dart';
import '../auth/authorization.dart';
import '../auth/contracts.dart';
import '../auth/encryption.dart';
import '../auth/env_encryption.dart';
import '../auth/hashing.dart';
import '../cache/cache.dart';
import '../database/database_config.dart';
import '../database/database_manager.dart';
import '../database/orm/model.dart';
import '../database/orm/model_definition.dart';
import '../database/orm/model_registry.dart';
import '../database/schema/migration.dart';
import '../database/seeding/seeder.dart';
import '../observability/health.dart';
import '../observability/metrics.dart';
import '../support/brand.dart';
import '../translation/translator.dart';
import '../storage/storage.dart';
import '../events/events.dart';
import '../http/client.dart';
import '../http/exception_handler.dart';
import '../http/headers.dart';
import '../http/middleware/maintenance_mode.dart';
import '../http/middleware/validate_signature.dart';
import '../http/kernel.dart';
import '../features/feature.dart';
import '../http/middleware.dart';
import '../http/middleware/cache_headers.dart';
import '../http/rate_limiter.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../http/server_engine.dart';
import '../logging/logger.dart';
import '../queue/drivers.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';
import '../routing/openapi.dart';
import '../routing/router.dart';
import '../routing/url_signer.dart';
import '../schedule/schedule.dart';
import '../server/coordinator.dart';
import '../server/supervisor.dart';
import 'config.dart';
import 'config_validator.dart';
import 'container.dart';
import 'locale.dart';
import 'env.dart';
import 'exceptions.dart';
import 'service_provider.dart';

part 'cache_rate_limit_store.dart';
part 'embedded_workers.dart';

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
    env = await Env.load(
      basePath: basePath,
      overrides: _builder._envOverrides,
      decrypt: (contents, key) => EnvironmentEncrypter(key).decrypt(contents),
    );
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
    // Laravel's `app.schedule_timezone`; tasks without their own zone use it.
    final scheduleZone = env.maybeString('SCHEDULE_TIMEZONE') ?? '';
    final schedule = Schedule(
      timezone: scheduleZone.isEmpty ? null : scheduleZone,
    );
    final cacheConfig = config.section<CacheConfig>();
    final limiterStore = cacheConfig.limiter;
    final rateLimiter = RateLimiter(
      store: limiterStore == null || limiterStore == 'process'
          ? ProcessRateLimitStore(
              channel,
              onError: (error) =>
                  logger.warning('Rate limiter fail-open: $error'),
            )
          // CACHE_LIMITER=database (or another store): limits shared
          // wherever that store is.
          : CacheRateLimitStore(
              () => container.make<CacheManager>().store(limiterStore).store,
              prefix: '${cacheConfig.prefix}rate_limiter:',
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
          drivers: _builder._databaseDrivers,
        ),
      )
      ..singleton<Migrator>(
        (c) => Migrator(c.make<DatabaseManager>(), _builder._migrations),
      )
      ..instance<SeederRegistry>(SeederRegistry(_builder._seeders))
      ..instance<ModelRegistry>(ModelRegistry(_builder._models))
      ..instance<Translator>(_translator())
      ..singleton<FeatureManager>(
        (c) => FeatureManager(switch (env.string(
          'PENNANT_STORE',
          config.section<AppConfig>().env == 'testing' ? 'array' : 'database',
        )) {
          'array' => ArrayFeatureStore(),
          'database' => DatabaseFeatureStore(c.make<DatabaseManager>()),
          final other => throw ConfigException(
            'PENNANT_STORE must be array or database, not $other.',
          ),
        }),
      )
      ..singleton<HashManager>(
        (c) => HashManager(c.make<ConfigRepository>().section<HashConfig>()),
      )
      ..singleton<Encrypter>((c) => _encrypter(c.make<Env>()))
      ..singleton<HttpClientFactory>((_) => HttpClientFactory())
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
      ..aliasFactory('cache.headers', CacheHeadersMiddleware.fromParams)
      ..aliasFactory(
        'feature',
        (params) => EnsureFeaturesAreActive(
          params,
          debug: config.section<AppConfig>().debug,
        ),
      )
      ..aliasFactory(
        'throttle',
        (params) => ThrottleMiddleware.fromParams(
          params,
          limiter: rateLimiter,
          userKeyResolver: (_) => _currentUserId(auth),
        ),
      );

    _builder._middlewareConfig?.call(middleware);
    // `dartisan down`: answer 503 except for the health probes.
    final health = _builder._routing?.health;
    middleware.prepend(
      PreventRequestsDuringMaintenance(
        MaintenanceMode.at(basePath),
        except: {
          if (health != null) ...{
            health,
            '${health == '/' ? '' : health}/ready',
          },
        },
      ),
    );
    final metricsConfig = config.section<MetricsConfig>();
    if (metricsConfig.enabled) {
      middleware.prepend(MetricsMiddleware(metrics));
      _metricsTimer = metrics.startPublishing();
    }
    _builder._exceptionsConfig?.call(exceptions);

    for (final configure in _builder._bindings) {
      configure(container);
    }
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
              onForeignJob: (queue, id, handler) => logger.warning(
                'Skipped a job pushed by another runtime (Laravel?) on queue '
                '[$queue]; give Daravel and Laravel workers separate queue '
                'names.',
                {'job_id': id, 'handler': handler},
              ),
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
      cipher: EncryptionCipher.parse(env.string('APP_CIPHER', 'AES-256-CBC')),
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
    // Live API reference (Laravel Scramble): local only unless API_DOCS.
    final appConfig = config.section<AppConfig>();
    if (env.boolean('API_DOCS', appConfig.env == 'local')) {
      final docs = env.string('API_DOCS_PATH', '/docs/api');
      router
          .get(docs, (_) => _apiDocsPage('$docs.json'))
          .name('daravel.api-docs');
      router
          .get('$docs.json', (_) => Response.json(_apiDocument()))
          .name('daravel.api-docs.json');
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

  /// The translator: `APP_LOCALE`, `APP_FALLBACK_LOCALE`, the lines from
  /// [ApplicationBuilder.withTranslations] and `lang/<locale>.json`.
  Translator _translator() {
    setApplicationLocale(config.section<AppConfig>().locale);
    final translator = Translator(
      fallback: env.string('APP_FALLBACK_LOCALE', 'en'),
    );
    for (final MapEntry(:key, :value) in _builder._translations.entries) {
      translator.addLines(value, key);
    }
    final lang = Directory('$basePath${Platform.pathSeparator}lang');
    if (lang.existsSync()) {
      for (final file in lang.listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (!name.endsWith('.json')) {
          continue;
        }
        final Object? json;
        try {
          json = jsonDecode(file.readAsStringSync());
        } on FormatException catch (error) {
          throw ConfigException('lang/$name is not valid JSON: $error');
        }
        if (json is! Map<String, Object?>) {
          throw ConfigException('lang/$name must be a JSON object.');
        }
        translator.addJson(json, name.substring(0, name.length - 5));
      }
    }
    return translator;
  }

  Map<String, Object?>? _openApi;

  /// The OpenAPI document of the compiled routes, built once.
  Map<String, Object?> _apiDocument() => _openApi ??= buildOpenApi(
    router.routes,
    title: '${config.section<AppConfig>().name} API',
  );

  /// Scalar options: no hosted toolbar, AI agent or MCP generator (they
  /// point to Scalar's services, not this application).
  static const String _scalarConfiguration =
      '{"showDeveloperTools":"never","agent":{"disabled":true},'
      '"mcp":{"disabled":true}}';

  /// The interactive reference (Scalar) for the document at [specUrl].
  Response _apiDocsPage(String specUrl) {
    String escape(String text) => text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
    final name = escape(config.section<AppConfig>().name);
    return Response.html('''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name API</title>
<link rel="icon" href="$daravelFaviconDataUri">
</head>
<body>
<script id="api-reference" data-url="${escape(specUrl)}" data-configuration="${escape(_scalarConfiguration)}"></script>
<script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.73.1"></script>
</body>
</html>
''');
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
  ///
  /// With [embedQueue] / [embedScheduler] (or `SERVER_EMBED_QUEUE` /
  /// `SERVER_EMBED_SCHEDULER`), a queue worker and the scheduler run in their
  /// own isolates in the same process and stop with the server.
  /// [commandRunner] lets the embedded scheduler run console commands (the
  /// CLI passes its own); without it, scheduled commands fail and are logged.
  static Future<int> serveWith(
    ApplicationFactory factory, {
    String? host,
    int? port,
    int? isolates,
    bool? embedQueue,
    bool? embedScheduler,
    ScheduleCommandRunner? commandRunner,
  }) async {
    final probe = factory();
    await probe.boot();
    final options = ServeOptions.fromEnv(
      probe.env,
      host: host,
      port: port,
      isolates: isolates,
      embedQueue: embedQueue,
      embedScheduler: embedScheduler,
    );
    probe._ensureServeable(options);
    final roles = [
      if (options.embedQueue) EmbeddedRole.queue,
      if (options.embedScheduler) EmbeddedRole.scheduler,
    ];
    final embedded = roles.isEmpty
        ? null
        : EmbeddedWorkers(
            factory,
            roles: roles,
            logger: probe.logger,
            commandRunner: commandRunner,
          );
    await embedded?.start();
    try {
      if (options.isolates <= 1) {
        await probe.serve(options: options);
        return 0;
      }
      final logger = probe.logger;
      await probe.shutdown();
      return await Supervisor(factory, options, logger: logger).run();
    } finally {
      await embedded?.stop(timeout: options.shutdownTimeout);
    }
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
    if (connection?.driver != 'sqlite' || connection?.database != ':memory:') {
      return;
    }
    if (resolved.isolates > 1) {
      throw ConfigException(
        'An in-memory SQLite database cannot be shared across '
        '${resolved.isolates} isolates (each isolate would get its own empty '
        'database). Use a file database or run with isolates: 1.',
      );
    }
    if (resolved.embedQueue || resolved.embedScheduler) {
      throw const ConfigException(
        'An in-memory SQLite database cannot be shared with the embedded '
        'queue or scheduler isolate. Use a file database.',
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
    container.resolved<HttpClientFactory>()?.close();
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
  final List<void Function(Container container)> _bindings =
      <void Function(Container container)>[];
  final List<Migration> _migrations = <Migration>[];
  final Map<String, DatabaseDriverFactory> _databaseDrivers = {};
  final List<Seeder> _seeders = <Seeder>[];
  final List<ModelDefinition<Model>> _models = <ModelDefinition<Model>>[];
  final Map<String, Map<String, Object?>> _translations = {};

  /// Registers translation lines by locale (Laravel's `lang/<locale>/*.php`):
  /// `{'en': {'auth.failed': '...'}, 'id': {...}}`; nested maps become
  /// dotted keys. `lang/<locale>.json` files are loaded as well.
  ApplicationBuilder withTranslations(Map<String, Map<String, Object?>> lines) {
    for (final MapEntry(:key, :value) in lines.entries) {
      (_translations[key] ??= {}).addAll(value);
    }
    return this;
  }

  /// Registers the application's models (`bootstrap/models.dart`), read by
  /// `dartisan model:show` and `mcp:serve`.
  ApplicationBuilder withModels(List<ModelDefinition<Model>> models) {
    _models.addAll(models);
    return this;
  }

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

  /// Registers services without a [ServiceProvider] class:
  ///
  /// ```dart
  /// .withBindings((c) {
  ///   c.singleton<PaymentGateway>((c) => MidtransGateway(c()));
  ///   c.scoped<TenantContext>((c) => TenantContext.of(c()));
  /// })
  /// ```
  ///
  /// Runs after the framework's own bindings (so it can replace one) and
  /// before the providers register (so they can use these).
  ApplicationBuilder withBindings(
    void Function(Container container) configure,
  ) {
    _bindings.add(configure);
    return this;
  }

  ApplicationBuilder withProviders(List<ServiceProvider> providers) {
    _providers.addAll(providers);
    return this;
  }

  /// Registers the driver for connections whose `driver` is [name], for
  /// example `withDatabaseDriver('mysql', MySqlDriver.fromConfig)` from
  /// package:daravel_mysql.
  ApplicationBuilder withDatabaseDriver(
    String name,
    DatabaseDriverFactory factory,
  ) {
    _databaseDrivers[name] = factory;
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
