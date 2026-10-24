import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
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
