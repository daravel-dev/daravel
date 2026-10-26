import 'package:daravel/daravel.dart' as core;
import 'package:daravel_postgres/daravel_postgres.dart';
import 'package:test/test.dart';

void main() {
  test('exports the core driver itself', () {
    expect(PostgresDriver, core.PostgresDriver);
    expect(PostgresSslMode.require, core.PostgresSslMode.require);
  });

  test('fromConfig reads host, port, pool and TLS from the connection', () {
    final driver = PostgresDriver.fromConfig(
      'main',
      const core.ConnectionConfig(
        driver: 'pgsql',
        database: 'app',
        host: 'db.internal',
        port: 6432,
        username: 'app',
        options: {'pool': 4, 'sslmode': 'verify-full'},
      ),
    );
    expect(driver.name, 'main');
    expect(driver.host, 'db.internal');
    expect(driver.port, 6432);
    expect(driver.database, 'app');
    expect(driver.maxConnections, 4);
    expect(driver.sslMode, PostgresSslMode.verifyFull);
  });

  test('an application on pgsql boots with withPostgres', () async {
    // Booting does not connect, so no server is needed.
    final app = core.Application.configure(basePath: '.')
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'pgsql',
          'DB_DATABASE': 'app',
        })
        .withPostgres()
        .create();
    await app.boot();
    await app.shutdown();
  });

  test('defaults match the built-in driver', () {
    final driver = PostgresDriver.fromConfig(
      'pgsql',
      const core.ConnectionConfig(driver: 'pgsql', database: 'app'),
    );
    expect(driver.host, '127.0.0.1');
    expect(driver.port, 5432);
    expect(driver.maxConnections, 10);
    expect(driver.sslMode, PostgresSslMode.disable);
  });
}
