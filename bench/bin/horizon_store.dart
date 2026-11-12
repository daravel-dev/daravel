// How fast Horizon's stores take the records of finished jobs, so the
// database store's batch (every 250 ms or 100 jobs) has a measured basis.
//
//   dart run bin/horizon_store.dart [--jobs=20000] [--pg=postgres://...]
//
// For each store it records --jobs finished jobs as fast as one isolate can,
// then waits until they are written, and prints records a second and the
// rows written. The database store runs with its batch (100) and with a
// batch of 1 (a statement per job), on a SQLite file and, with --pg, on
// PostgreSQL.
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';

Future<void> main(List<String> argv) async {
  String? option(String name) => [
    for (final a in argv)
      if (a.startsWith('--$name=')) a.substring(name.length + 3),
  ].lastOrNull;
  final jobs = int.parse(option('jobs') ?? '20000');
  final pg = option('pg');

  stdout.writeln('| Store | Database | Batch | Jobs | Records/s | Rows |');
  stdout.writeln('| :-- | :-- | --: | --: | --: | --: |');

  // The process store: the coordinator's HorizonService in this isolate.
  final coordinator = createStandardCoordinator()..register(HorizonService());
  final channel = LocalCoordinatorChannel(coordinator);
  await _run(
    'process',
    '-',
    0,
    jobs,
    ProcessHorizonStore(() => channel),
    () async {
      final summary = await ProcessHorizonStore(() => channel).summary();
      return summary['jobs_past_hour']! as int;
    },
  );
  coordinator.close();

  final targets = <String, Map<String, String>>{
    'SQLite file': {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE':
          '${Directory.systemTemp.createTempSync('horizon_store_bench_').path}'
          '${Platform.pathSeparator}db.sqlite',
    },
    if (pg != null) 'PostgreSQL': {'DB_CONNECTION': 'pgsql', 'DB_URL': pg},
  };
  for (final MapEntry(key: database, value: env) in targets.entries) {
    for (final batch in const [100, 1]) {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', ...env})
          .withLogLevel(LogLevel.critical)
          .create();
      await app.boot();
      await app.run(() async {
        final schema = await Schema.builder();
        await const CreateHorizonTables().down(schema);
        await const CreateHorizonTables().up(schema);
      });
      final store = DatabaseHorizonStore(
        app.container.make<DatabaseManager>(),
        batchSize: batch,
        maxBuffered: jobs,
      );
      await _run('database', database, batch, jobs, store, () async {
        await store.flush();
        return app.run(() => DB.table('horizon_jobs').count());
      });
      await app.run(
        () async => const CreateHorizonTables().down(await Schema.builder()),
      );
      await app.shutdown();
    }
  }
}

Future<void> _run(
  String name,
  String database,
  int batch,
  int jobs,
  HorizonStore store,
  Future<int> Function() settle,
) async {
  final now = Clock.now().millisecondsSinceEpoch;
  final watch = Stopwatch()..start();
  for (var i = 0; i < jobs; i++) {
    await store.record(
      RecordedJob(
        uuid: 'bench-$i',
        name: 'SendInvoice',
        queue: 'default',
        status: 'completed',
        at: now + i,
        durationMs: 5,
      ),
    );
  }
  final rows = await settle();
  watch.stop();
  final perSecond = jobs / (watch.elapsedMicroseconds / 1e6);
  stdout.writeln(
    '| $name | $database | ${batch == 0 ? '-' : batch} | $jobs | '
    '${perSecond.toStringAsFixed(0)} | $rows |',
  );
}
