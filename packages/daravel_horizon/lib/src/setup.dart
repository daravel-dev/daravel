import 'dart:async';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'events.dart';
import 'master.dart';
import 'routes.dart';
import 'store/database_store.dart';
import 'store/horizon_store.dart';
import 'store/process_store.dart';

/// `withHorizon()` (Blueprint #134 §3.2).
extension HorizonApplicationBuilder on ApplicationBuilder {
  /// Registers Horizon: the `horizon` config section ([HorizonConfig] from
  /// `HORIZON_*`, with [plans] and the [environments] overrides), its
  /// checks, the [HorizonService] store on the process's coordinator, and
  /// the embedded worker `horizon`, which `serve --embed-worker=horizon`
  /// starts: a [HorizonMaster] running the supervisors beside the HTTP
  /// server.
  ///
  /// [createApp] is the application's own factory (the top-level function
  /// passed to `Application.serveWith`): each worker isolate builds its
  /// application with it, and Dart cannot find it by itself.
  ///
  /// The dashboard's API is served at `HORIZON_PATH` (`/horizon`) behind
  /// [middleware]; outside `APP_ENV=local` and `testing` it answers 403
  /// until [middleware] protects it (`['auth', 'can:viewHorizon']`).
  ApplicationBuilder withHorizon({
    required ApplicationFactory createApp,
    List<SupervisorPlan> plans = const [
      SupervisorPlan(name: SupervisorName('supervisor-1')),
    ],
    Map<String, List<SupervisorPlan>> environments = const {},
    Map<String, Duration>? waits,
    List<Object> middleware = const [],
  }) =>
      withConfig<HorizonConfig>(
            (env) => HorizonConfig.fromEnv(
              env,
              defaults: plans,
              environments: environments,
              waits: waits,
            ),
          )
          .withConfigCheck(HorizonConfig.check)
          .withCoordinatorService(HorizonService.new)
          // HORIZON_STORE: `process`, this process's coordinator; the
          // stores other packages register come through the drivers.
          .withBindings(
            (container) => container
              ..singleton<HorizonStoreDrivers>((_) => HorizonStoreDrivers())
              ..singleton<HorizonStore>(_storeFor),
          )
          // Before the connections close: what the workers recorded last
          // is written, not lost with the process.
          .withShutdown((c) async {
            if (c.resolved<HorizonStore>() case final BufferedHorizonStore s) {
              await s.close();
            }
          })
          .withEmbeddedWorker(
            'horizon',
            (app, control) => runHorizon(app, control, createApp),
          )
          .withProviders([_HorizonRoutes(middleware)]);
}

/// The store `HORIZON_STORE` names: `process` (the default, this process's
/// coordinator) or `database` (the tables of [CreateHorizonTables] on
/// `HORIZON_STORE_CONNECTION`), or one registered in [HorizonStoreDrivers]:
/// `redis` by `daravel_redis`'s `withRedis()`.
HorizonStore _storeFor(Container c) {
  final config = c.make<ConfigRepository>().section<HorizonConfig>();
  if (c.make<HorizonStoreDrivers>().make(config.store, c) case final store?) {
    return store;
  }
  return switch (config.store) {
    'process' => ProcessHorizonStore(() => c.make<CoordinatorChannel>()),
    'database' => DatabaseHorizonStore(
      c.make<DatabaseManager>(),
      connection: config.storeConnection,
      retention: config.trim.completed,
      failedRetention: config.trim.failed,
      monitoredRetention: config.trim.monitored,
      appMetrics: c.make<AppMetrics>(),
      logger: c.make<Logger>(),
    ),
    final other => throw ConfigException(
      'HORIZON_STORE=$other is not available: use process or database '
      '(redis needs daravel_redis and withRedis()).',
    ),
  };
}

/// Registers the dashboard's routes at boot, where `HORIZON_PATH` is known.
final class _HorizonRoutes extends ServiceProvider {
  _HorizonRoutes(this.middleware);

  final List<Object> middleware;

  @override
  void boot(Container container) {
    // HORIZON_STORE is resolved now: a store that cannot be built (redis
    // without withRedis()) stops the boot with its ConfigException, rather
    // than leaving the dashboard empty or failing at the first job.
    container.make<HorizonStore>();
    final configured = container
        .make<ConfigRepository>()
        .section<HorizonConfig>()
        .path;
    final path = configured.length > 1 && configured.endsWith('/')
        ? configured.substring(0, configured.length - 1)
        : configured;
    final routes = HorizonRoutes(path: path, middleware: middleware);
    container.instance<HorizonRoutes>(routes);
    HorizonDashboard.routes(
      container.make<Router>(),
      path: path,
      middleware: middleware,
    );
  }
}

/// Where `withHorizon()` serves the dashboard and behind what: for
/// `dartisan horizon --dashboard`, which serves it on a port of its own.
final class HorizonRoutes {
  /// The dashboard at [path] behind [middleware].
  const HorizonRoutes({required this.path, this.middleware = const []});

  /// `HORIZON_PATH`, without a trailing slash.
  final String path;

  /// The middleware of `withHorizon(middleware:)`.
  final List<Object> middleware;
}

/// What a [HorizonMaster] of [app] does about the database sessions of a
/// worker isolate it kills, whose sockets stay open while the process
/// lives:
/// - `terminate` ends them through the application's own driver
///   ([SessionTerminatingDriver]: PostgreSQL, MySQL, MariaDB) before the
///   job is reclaimed;
/// - `restartAfterKill` is `sqlite_lock` for a SQLite file queue, or
///   `sessions_not_terminable` for a server database whose driver cannot
///   end sessions: a kill then needs a fresh process;
/// - `idleTransactionTimeout` is the `DB_IDLE_TRANSACTION_TIMEOUT` the
///   workers get (`HORIZON_IDLE_TX_TIMEOUT`), unless the environment sets
///   its own.
typedef HorizonKillPolicy = ({
  Future<bool> Function(String connection, String id)? terminate,
  String? restartAfterKill,
  Duration? idleTransactionTimeout,
});

/// The [HorizonKillPolicy] of [app]; opens its default database connection
/// to see whether the driver can end sessions.
Future<HorizonKillPolicy> horizonKillPolicy(Application app) async {
  final config = app.config.section<HorizonConfig>();
  final database = app.container.make<DatabaseManager>();
  final idle = app.env.maybeString('DB_IDLE_TRANSACTION_TIMEOUT') == null
      ? config.workerIdleTransactionTimeout
      : null;
  Future<bool> terminate(String connection, String id) async {
    final driver = await database.connection(connection);
    return driver is SessionTerminatingDriver &&
        await driver.terminateSession(id);
  }

  if (HorizonConfig.onSqliteFile(app.config)) {
    return (
      terminate: null,
      restartAfterKill: 'sqlite_lock',
      idleTransactionTimeout: idle,
    );
  }
  final db = app.config.section<DatabaseConfig>();
  if (db.connections[db.defaultConnection]?.driver == 'sqlite') {
    return (
      terminate: null,
      restartAfterKill: null,
      idleTransactionTimeout: idle,
    );
  }
  try {
    if (await database.connection() is! SessionTerminatingDriver) {
      app.logger.warning(
        'Horizon: the database driver cannot end the sessions of a killed '
        'worker; after a kill Horizon stops for a restart.',
      );
      return (
        terminate: null,
        restartAfterKill: 'sessions_not_terminable',
        idleTransactionTimeout: idle,
      );
    }
  } on Object catch (e) {
    // Not reachable now: ending sessions is tried again after a kill.
    app.logger.warning('Horizon: the database is not reachable: $e');
  }
  return (
    terminate: terminate,
    restartAfterKill: null,
    idleTransactionTimeout: idle,
  );
}

/// The embedded `horizon` worker: runs a [HorizonMaster] for [app]'s
/// config until the server stops, obeying `pause` and `continue` sent with
/// `EmbeddedWorkers.send('horizon', ...)`. With `HORIZON_ENABLED=false` it
/// only waits for the stop.
Future<int> runHorizon(
  Application app,
  EmbeddedControl control,
  ApplicationFactory createApp,
) async {
  final config = app.config.section<HorizonConfig>();
  if (config.enabled && HorizonConfig.embedRefused(app.config)) {
    // Reached by `serve --embed-worker=horizon` (the flag does not go
    // through the environment the config check reads). Waits for the
    // stop rather than ending, which would start it again and again.
    app.logger.error(HorizonConfig.embedSqliteMessage);
    await control.stopping;
    return 0;
  }
  if (!config.enabled) {
    app.logger.info('Horizon disabled (HORIZON_ENABLED=false).');
    await control.stopping;
    return 0;
  }
  final queues = app.container.make<QueueManager>();
  final policy = await horizonKillPolicy(app);
  final master = HorizonMaster(
    createApp,
    config,
    terminateSession: policy.terminate,
    workerIdleTransactionTimeout: policy.idleTransactionTimeout,
    driver: queues.connection,
    logger: app.logger,
    coordinator: control.coordinator,
    store: app.container.make<CoordinatorChannel>(),
    horizonStore: horizonStoreOf(app.container),
    failedJobs: queues.processor.failedJobs,
    signals: queues.signalStore,
    name: config.name ?? 'horizon',
    onEvent: horizonEvents(app),
    failsAfterTimeout: queues.processor.failsAfterTimeout,
  );
  await master.start();
  final commands = control.messages.listen((message) {
    switch (message) {
      case 'pause':
        master.pause();
      case 'continue':
        master.resume();
    }
  });
  final drain = await control.stopping;
  await commands.cancel();
  await master.stop(timeout: drain);
  return 0;
}
