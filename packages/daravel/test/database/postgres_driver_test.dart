import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  timeoutOptionTests();
  group('PostgresDriver unix sockets', () {
    PostgresDriver driver(String host, {int port = 5432}) =>
        PostgresDriver(host: host, port: port, database: 'app');

    test('TCP hosts are not sockets', () {
      expect(driver('127.0.0.1').unixSocketPath, isNull);
      expect(driver('db.internal').unixSocketPath, isNull);
    });

    test('a directory gets the libpq socket file name (Cloud SQL)', () {
      expect(
        driver('/cloudsql/project:region:db').unixSocketPath,
        '/cloudsql/project:region:db/.s.PGSQL.5432',
      );
      expect(
        driver('/var/run/postgresql/', port: 6432).unixSocketPath,
        '/var/run/postgresql/.s.PGSQL.6432',
      );
    });

    test('a full socket path is kept', () {
      expect(driver('/tmp/.s.PGSQL.5432').unixSocketPath, '/tmp/.s.PGSQL.5432');
    });
  });
}

void timeoutOptionTests() {
  test('DB_CONNECT_TIMEOUT and DB_QUERY_TIMEOUT reach the driver', () {
    PostgresDriver of(Map<String, Object?> options) =>
        PostgresDriver.fromConfig(
          'pgsql',
          ConnectionConfig(driver: 'pgsql', database: 'd', options: options),
        );
    final defaults = of(const {});
    expect(defaults.connectTimeout, const Duration(seconds: 10));
    expect(defaults.queryTimeout, const Duration(seconds: 30));
    // As Env hands them over: strings.
    final set = of(const {'connect_timeout': '3', 'query_timeout': '120'});
    expect(set.connectTimeout, const Duration(seconds: 3));
    expect(set.queryTimeout, const Duration(minutes: 2));
    // 0 means none: longer than any deployment for a driver whose timeout
    // cannot be absent.
    final none = of(const {'query_timeout': '0'});
    expect(none.queryTimeout, PostgresDriver.noTimeout);
    expect(PostgresDriver.timeoutOption(null, Duration.zero), Duration.zero);
    expect(PostgresDriver.timeoutOption('x', Duration.zero), Duration.zero);
    expect(PostgresDriver.timeoutOption(-1, Duration.zero), isNull);
    expect(
      PostgresDriver.timeoutOption(7, Duration.zero),
      const Duration(seconds: 7),
    );
  });
}
