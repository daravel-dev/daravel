import 'dart:async';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'master.dart';
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
  ApplicationBuilder withHorizon({
    required ApplicationFactory createApp,
    List<SupervisorPlan> plans = const [
      SupervisorPlan(name: SupervisorName('supervisor-1')),
    ],
    Map<String, List<SupervisorPlan>> environments = const {},
    Map<String, Duration>? waits,
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
  final master = HorizonMaster(
    createApp,
    config,
    driver: queues.connection,
    logger: app.logger,
    coordinator: control.coordinator,
    store: app.container.make<CoordinatorChannel>(),
    failedJobs: queues.processor.failedJobs,
    signals: queues.signalStore,
    name: config.name ?? 'horizon',
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
