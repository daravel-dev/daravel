import 'package:daravel/daravel.dart';

import 'apps.dart';
import 'config.dart';
import 'routes.dart';
import 'server.dart';

/// `withReverb()` (Blueprint #135 §3.2).
extension ReverbApplicationBuilder on ApplicationBuilder {
  /// Registers Reverb beside `withBroadcasting()`, which it needs: the
  /// `reverb` config section ([ReverbConfig] from `REVERB_*`) and its
  /// checks, the applications the Pusher server serves ([apps]: by
  /// `REVERB_APPS_PROVIDER` unless given, see [ReverbApps]), and the
  /// `reverb:restart` watcher of the isolates `dartisan reverb:start` runs.
  ///
  /// The dashboard is served at [dashboard] (`/reverb`; empty for none)
  /// behind [middleware]; outside `APP_ENV=local` and `testing` it answers
  /// 403 until [middleware] protects it (`['auth', 'can:viewReverb']`).
  /// `reverb:start` does not serve it: the HTTP application does.
  ApplicationBuilder withReverb({
    ReverbAppsFactory apps = ReverbApps.fromSource,
    String dashboard = '/reverb',
    List<Object> middleware = const [],
  }) => withConfig<ReverbConfig>(ReverbConfig.fromEnv)
      .withConfigCheck(ReverbConfig.check)
      .withBroadcastApps(apps)
      .withProviders([_ReverbProvider(dashboard, middleware)])
      .withShutdown((c) async => c.resolved<ReverbRestartWatcher>()?.stop());
}

final class _ReverbProvider extends ServiceProvider {
  _ReverbProvider(this.dashboard, this.middleware);

  final String dashboard;
  final List<Object> middleware;

  @override
  void boot(Container container) {
    final app = container.make<Application>();
    if (app.servesBroadcastingOnly) {
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
    final path = dashboard.length > 1 && dashboard.endsWith('/')
        ? dashboard.substring(0, dashboard.length - 1)
        : dashboard;
    if (path.isNotEmpty) {
      ReverbDashboard.routes(
        container.make<Router>(),
        path: path,
        middleware: middleware,
      );
    }
  }
}
