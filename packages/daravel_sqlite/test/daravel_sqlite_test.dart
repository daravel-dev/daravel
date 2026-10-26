import 'package:daravel/daravel.dart' as core;
import 'package:daravel_sqlite/daravel_sqlite.dart';
import 'package:test/test.dart';

void main() {
  test('exports the core driver itself', () {
    expect(SqliteDriver, core.SqliteDriver);
  });

  test('fromConfig opens the configured database', () async {
    final driver = SqliteDriver.fromConfig(
      'local',
      const core.ConnectionConfig(driver: 'sqlite', database: ':memory:'),
    );
    await driver.connect();
    addTearDown(driver.close);
    expect(driver.name, 'local');
    final rows = await driver.select('select 1 + 1 as two', const []);
    expect(rows.single['two'], 2);
  });

  test('an application can register it explicitly', () async {
    final app = core.Application.configure(basePath: '.')
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withSqlite()
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final rows = await core.DB.select('select 3 as n');
    expect(rows.single['n'], 3);
  });
}
