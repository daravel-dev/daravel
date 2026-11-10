import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

Application doctorApp({
  required bool embedded,
}) => Application.configure(basePath: Directory.systemTemp.path)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE':
          '${Directory.systemTemp.path}${Platform.pathSeparator}doctor_$pid.sqlite',
      'QUEUE_CONNECTION': 'database',
      'HORIZON_ALLOW_SQLITE': 'true',
      if (embedded) 'SERVER_EMBED_WORKERS': 'horizon',
    })
    .withLogLevel(LogLevel.critical)
    .withHorizon(createApp: () => doctorApp(embedded: embedded))
    .create();

void main() {
  test(
    'doctor: embedded Horizon on SQLite, allowed for development only',
    () async {
      final app = doctorApp(embedded: true);
      await app.boot();
      addTearDown(app.shutdown);
      final dev = horizonSqliteCheck(app, production: false)!;
      expect(dev.status, CheckStatus.warning);
      expect(dev.title, contains('HORIZON_ALLOW_SQLITE'));
      expect(
        horizonSqliteCheck(app, production: true)!.status,
        CheckStatus.error,
      );
    },
  );

  test('doctor: nothing without embedding', () async {
    final app = doctorApp(embedded: false);
    await app.boot();
    addTearDown(app.shutdown);
    expect(horizonSqliteCheck(app, production: true), isNull);
  });
}
