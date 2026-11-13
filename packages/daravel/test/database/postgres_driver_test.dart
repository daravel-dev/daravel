import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  timeoutOptionTests();
  group('DB_SSLMODE', () {
    ({PostgresSslMode mode, String? warning}) of(Object? mode) =>
        PostgresDriver.sslModeOf(mode);

    test('the libpq modes, in any case, without a warning', () {
      for (final (value, mode) in [
        (null, PostgresSslMode.disable),
        ('', PostgresSslMode.disable),
        ('disable', PostgresSslMode.disable),
        ('DISABLE', PostgresSslMode.disable),
        ('require', PostgresSslMode.require),
        ('REQUIRE', PostgresSslMode.require),
        ('verify-full', PostgresSslMode.verifyFull),
        ('verify_full', PostgresSslMode.verifyFull),
        ('verifyFull', PostgresSslMode.verifyFull),
      ]) {
        expect(
          (of(value).mode, of(value).warning),
          (mode, null),
          reason: '$value',
        );
      }
    });

    test('verify-ca verifies, with a warning', () {
      for (final value in ['verify-ca', 'VERIFY_CA']) {
        expect(of(value).mode, PostgresSslMode.verifyFull, reason: value);
        expect(of(value).warning, isNotNull, reason: value);
      }
    });

    test('prefer and allow stay without TLS, with a warning', () {
      for (final value in ['prefer', 'allow', 'PREFER']) {
        expect(of(value).mode, PostgresSslMode.disable, reason: value);
        expect(
          of(value).warning,
          allOf(
            contains('"$value"'),
            contains('require'),
            contains('verify-full'),
          ),
          reason: value,
        );
      }
    });

    // DB-1 (Reviewer RSEQ 49 #4a): `required` meant no TLS with a warning.
    test('any other value is a ConfigException naming the six modes', () {
      for (final value in ['required', 'requird', 'verify-fulll', 'tls', '1']) {
        expect(
          () => of(value),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('"$value"'),
                contains(
                  'disable, allow, prefer, require, verify-ca or '
                  'verify-full',
                ),
              ),
            ),
          ),
          reason: value,
        );
      }
    });

    test('the boot check refuses an unknown mode on a PostgreSQL default '
        'connection only', () {
      Iterable<ConfigIssue> check(Map<String, String> env) {
        final config = ConfigRepository()
          ..register<DatabaseConfig>(
            DatabaseConfig.fromEnv(Env.fromMap(env), basePath: '/srv'),
          );
        return DatabaseConfig.check(Env.fromMap(env), config);
      }

      expect(
        check({'DB_CONNECTION': 'pgsql', 'DB_SSLMODE': 'required'}).single,
        isA<ConfigIssue>()
            .having((i) => i.level, 'level', ConfigIssueLevel.error)
            .having((i) => i.message, 'message', contains('"required"')),
      );
      expect(
        check({'DB_CONNECTION': 'pgsql', 'DB_SSLMODE': 'verify-full'}),
        isEmpty,
      );
      expect(
        check({'DB_CONNECTION': 'mysql', 'DB_SSLMODE': 'REQUIRED'}),
        isEmpty,
        reason: 'a MySQL mode name feeds the unused pgsql entry too',
      );
    });

    test('DB_SSLROOTCERT, DB_SSLCERT and DB_SSLKEY reach the options, from '
        'env and DB_URL', () {
      final env = DatabaseConfig.fromEnv(
        Env.fromMap({
          'DB_SSLROOTCERT': '/ca.pem',
          'DB_SSLCERT': '/c.pem',
          'DB_SSLKEY': '/k.pem',
        }),
        basePath: '/srv',
      ).connections['pgsql']!.options;
      expect(
        [env['sslrootcert'], env['sslcert'], env['sslkey']],
        ['/ca.pem', '/c.pem', '/k.pem'],
      );
      final url = ConnectionConfig.fromUrl(
        'pgsql://u:p@h/db?sslmode=verify-full&sslrootcert=/ca.pem'
        '&sslcert=/c.pem&sslkey=/k.pem',
      ).options;
      expect(
        [url['sslrootcert'], url['sslcert'], url['sslkey']],
        ['/ca.pem', '/c.pem', '/k.pem'],
      );
    });

    test('securityContextOf: none, a missing file, a certificate without '
        'its key', () {
      expect(PostgresDriver.securityContextOf(), isNull);
      final missing = '${Directory.systemTemp.path}/no-such-ca-db1.pem';
      expect(
        () => PostgresDriver.securityContextOf(rootCert: missing),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('DB_SSLROOTCERT'), contains(missing)),
          ),
        ),
      );
      expect(
        () => PostgresDriver.securityContextOf(cert: '/c.pem'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => PostgresDriver.fromConfig(
          'pgsql',
          ConnectionConfig(
            driver: 'pgsql',
            database: 'd',
            options: {'sslmode': 'verify-full', 'sslrootcert': missing},
          ),
        ),
        throwsA(isA<ConfigException>()),
        reason: 'read when the driver is made, not at the first query',
      );
    });

    test('fromConfig warns once, naming the connection', () {
      final warnings = <String>[];
      final driver = PostgresDriver.fromConfig(
        'reporting',
        const ConnectionConfig(
          driver: 'pgsql',
          database: 'd',
          options: {'sslmode': 'verify-ca'},
        ),
        onWarning: warnings.add,
      );
      expect(driver.sslMode, PostgresSslMode.verifyFull);
      expect(warnings, hasLength(1));
      expect(warnings.single, startsWith('[reporting] '));
    });
  });
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

  test(
    'DB_IDLE_TRANSACTION_TIMEOUT reaches the driver; unset or 0 is none',
    () {
      PostgresDriver of(Map<String, Object?> options) =>
          PostgresDriver.fromConfig(
            'pgsql',
            ConnectionConfig(driver: 'pgsql', database: 'd', options: options),
          );
      expect(of(const {}).idleTransactionTimeout, isNull);
      expect(
        of(const {'idle_transaction_timeout': '0'}).idleTransactionTimeout,
        isNull,
      );
      expect(
        of(const {'idle_transaction_timeout': 'x'}).idleTransactionTimeout,
        isNull,
      );
      expect(
        of(const {'idle_transaction_timeout': '15'}).idleTransactionTimeout,
        const Duration(seconds: 15),
      );
      expect(
        PostgresDriver.idleTransactionStatement(const Duration(seconds: 15)),
        'set idle_in_transaction_session_timeout = 15000',
      );
      final config = DatabaseConfig.fromEnv(
        Env.fromMap(const {'DB_IDLE_TRANSACTION_TIMEOUT': '20'}),
        basePath: '.',
      );
      for (final name in ['pgsql', 'mysql', 'mariadb']) {
        expect(
          config.connections[name]!.options['idle_transaction_timeout'],
          '20',
          reason: name,
        );
      }
    },
  );
}
