// Run by `database_store_shutdown_test.dart` as a process of its own: an
// application with HORIZON_STORE=database records a job, then shuts down at
// once. The record must be written by the shutdown, before the database
// connections close; the parent process then reads the table.
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';

/// The application (top-level, as `withHorizon(createApp:)` needs); its
/// database file comes from `HORIZON_TEST_DB`.
Application storeApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': Platform.environment['HORIZON_TEST_DB']!,
          'HORIZON_STORE': 'database',
        })
        .withLogLevel(LogLevel.critical)
        .withMigrations(const [CreateHorizonTables()])
        .withHorizon(createApp: storeApp)
        .create();

Future<void> main() async {
  final app = storeApp();
  await app.boot();
  await app.run(() => App.make<Migrator>().run());
  final store = horizonStoreOf(app.container);
  stdout.writeln('store ${store.runtimeType}');
  await store.record(
    RecordedJob(
      uuid: 'last-before-stop',
      name: 'SendInvoice',
      queue: 'default',
      status: 'completed',
      at: Clock.now().millisecondsSinceEpoch,
    ),
  );
  // No flush: the buffer waits for its timer, and the shutdown comes first.
  await app.shutdown();
  stdout.writeln('after shutdown');
  // As a command runner does: the process ends here, timers or not.
  await stdout.flush();
  exit(0);
}
