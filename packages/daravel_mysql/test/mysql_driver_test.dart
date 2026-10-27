import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:mysql_dart/exception.dart';
import 'package:test/test.dart';

void main() {
  timeoutOptionTests();
  test('fromConfig reads the DB_* connection like Laravel', () {
    final driver = MySqlDriver.fromConfig(
      'mariadb',
      const ConnectionConfig(
        driver: 'mariadb',
        database: 'shop',
        host: 'db.internal',
        port: 3307,
        username: 'app',
        password: 'secret',
        options: {
          'pool': 4,
          'sslmode': 'require',
          'collation': 'utf8mb4_0900_ai_ci',
          'timezone': '+00:00',
        },
      ),
    );
    expect(driver.name, 'mariadb');
    expect(driver.dialect, SqlDialect.mysql);
    expect(driver.host, 'db.internal');
    expect(driver.port, 3307);
    expect(driver.maxConnections, 4);
    expect(driver.secure, isTrue);
    expect(driver.collation, 'utf8mb4_0900_ai_ci');
    expect(driver.timeZone, '+00:00');
    expect(driver.isConnected, isFalse);

    final plain = MySqlDriver.fromConfig(
      'mysql',
      const ConnectionConfig(driver: 'mysql', database: 'shop'),
    );
    expect(plain.secure, isFalse, reason: 'DB_SSLMODE defaults to disable');
    expect(plain.timeZone, isNull, reason: "the server's zone, as Laravel");
  });

  test('deadlocks and lock wait timeouts are retryable', () {
    final driver = MySqlDriver(host: 'x', database: 'y');
    expect(
      driver.isRetryableError(const MySQLServerException('Deadlock', 1213)),
      isTrue,
    );
    expect(
      driver.isRetryableError(const MySQLServerException('Lock wait', 1205)),
      isTrue,
    );
    expect(
      driver.isRetryableError(const MySQLServerException('Duplicate', 1062)),
      isFalse,
    );
  });

  test('without the package registered, the error says what to add', () {
    final db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'mysql',
        connections: {
          'mysql': ConnectionConfig(driver: 'mysql', database: 'shop'),
        },
      ),
    );
    expect(
      db.executor,
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains("withDatabaseDriver('mysql', MySqlDriver.fromConfig)"),
        ),
      ),
    );
  });
}

void timeoutOptionTests() {
  test('DB_QUERY_TIMEOUT and DB_CONNECT_TIMEOUT reach the driver', () {
    MySqlDriver of(Map<String, Object?> options) => MySqlDriver.fromConfig(
      'mysql',
      ConnectionConfig(driver: 'mysql', database: 'd', options: options),
    );
    final defaults = of(const {});
    expect(defaults.queryTimeout, const Duration(seconds: 30));
    expect(defaults.connectTimeout, const Duration(seconds: 10));
    final set = of(const {'query_timeout': '5', 'connect_timeout': '2'});
    expect(set.queryTimeout, const Duration(seconds: 5));
    expect(set.connectTimeout, const Duration(seconds: 2));
    expect(of(const {'query_timeout': '0'}).queryTimeout, isNull);
  });
}
