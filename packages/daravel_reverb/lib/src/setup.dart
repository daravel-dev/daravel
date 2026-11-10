import 'package:daravel/daravel.dart';

import 'apps.dart';
import 'config.dart';
import 'server.dart';

/// `withReverb()` (Blueprint #135 §3.2).
extension ReverbApplicationBuilder on ApplicationBuilder {
  /// Registers Reverb beside `withBroadcasting()`, which it needs: the
  /// `reverb` config section ([ReverbConfig] from `REVERB_*`) and its
  /// checks, the applications the Pusher server serves ([apps]: by
  /// `REVERB_APPS_PROVIDER` unless given, see [ReverbApps]), and the
  /// `reverb:restart` watcher of the isolates `dartisan reverb:start` runs.
  ///
  /// With [dashboard] middleware (`['auth', 'can:viewReverb']`), a stats
  /// page is served at [dashboardPath] (JSON for now; the dashboard of
  /// Blueprint #135 §3.6 follows). Without it there is no route.
  ApplicationBuilder withReverb({
    ReverbAppsFactory apps = ReverbApps.fromSource,
    List<Object> dashboard = const [],
    String dashboardPath = '/reverb',
  }) => withConfig<ReverbConfig>(ReverbConfig.fromEnv)
      .withConfigCheck(ReverbConfig.check)
      .withBroadcastApps(apps)
      .withProviders([_ReverbProvider(dashboard, dashboardPath)])
      .withSupervisorHook(_rollingReverbRestart)
      .withShutdown((c) async => c.resolved<ReverbRestartWatcher>()?.stop());
}

/// With several isolates the main isolate hears `reverb:restart`, once
/// for the process, and restarts the workers one at a time
/// ([Supervisor.rollingRestart]): the others keep accepting connections.
/// The workers watch nothing themselves ([Application.supervised]).
void Function()? _rollingReverbRestart(Application app, Supervisor supervisor) {
  if (!app.servesBroadcastingOnly) {
    return null;
  }
  final container = app.container;
  // The main isolate's application booted with its own watcher, which
  // would restart nothing: replaced by one that rolls the workers.
  container.resolved<ReverbRestartWatcher>()?.stop();
  final signals = container.make<QueueManager>().signalStore;
  if (signals == null) {
    return null;
  }
  final watcher = ReverbRestartWatcher(
    app,
    signals.store,
    spread: app.config.section<BroadcastConfig>().drainSpread,
    onRestart: () async {
      await supervisor.rollingRestart();
    },
  )..start();
  return watcher.stop;
}

final class _ReverbProvider extends ServiceProvider {
  _ReverbProvider(this.dashboard, this.path);

  final List<Object> dashboard;
  final String path;

  @override
  void boot(Container container) {
    final app = container.make<Application>();
    // A supervisor's worker: the main isolate rolls the restarts.
    if (app.servesBroadcastingOnly && !app.supervised) {
      final signals = container.make<QueueManager>().signalStore;
      if (signals == null) {
        app.logger.warning(
          'Reverb: the queue has no signal store; reverb:restart is not '
          'heard (set QUEUE_SIGNAL_STORE).',
        );
      } else {
        final watcher = ReverbRestartWatcher(
          app,
          signals.store,
          spread: app.config.section<BroadcastConfig>().drainSpread,
        )..start();
        container.instance<ReverbRestartWatcher>(watcher);
      }
    }
    if (dashboard.isNotEmpty) {
      container
          .make<Router>()
          .get(path, (_) => reverbStats(container))
          .name('reverb.stats')
          .middleware(dashboard);
    }
  }
}

/// What the stats page shows: the applications (without secrets) and
/// each isolate's last report ([ReverbStats]) on this process's
/// coordinator.
Future<Map<String, Object?>> reverbStats(Container container) async {
  final config = container.make<ConfigRepository>();
  final reverb = config.section<ReverbConfig>();
  final settings = config.section<BroadcastConfig>();
  return {
    'apps': [
      if (settings.serves) BroadcastApp.fromConfig(settings).toPublicMap(),
      for (final app in reverb.apps)
        if (app.id != settings.appId) app.toPublicMap(),
    ],
    'provider': reverb.source.name,
    'workers': await ReverbStats.collect(container.make<CoordinatorChannel>()),
  };
}
