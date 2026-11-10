import 'dart:async';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'events.dart';
import 'master.dart';
import 'routes.dart';
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
          .withEmbeddedWorker(
            'horizon',
            (app, control) => runHorizon(app, control, createApp),
          )
          .withProviders([_HorizonRoutes(middleware)]);
}

/// Registers the dashboard's routes at boot, where `HORIZON_PATH` is known.
final class _HorizonRoutes extends ServiceProvider {
  _HorizonRoutes(this.middleware);

  final List<Object> middleware;

  @override
  void boot(Container container) {
    final path = container
        .make<ConfigRepository>()
        .section<HorizonConfig>()
        .path;
    HorizonDashboard.routes(
      container.make<Router>(),
      path: path.length > 1 && path.endsWith('/')
          ? path.substring(0, path.length - 1)
          : path,
      middleware: middleware,
    );
  }
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
    failedJobs: queues.processor.failedJobs,
    signals: queues.signalStore,
    name: config.name ?? 'horizon',
    onEvent: horizonEvents(app),
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
