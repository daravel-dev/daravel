import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:mysql_dart/exception.dart';
import 'package:test/test.dart';

void main() {
  shutdownTests();
  timeoutOptionTests();
  test("sql_mode as Laravel 12's MySqlConnector sets it", () {
    const strict =
        'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,'
        'ERROR_FOR_DIVISION_BY_ZERO';
    expect(MySqlDriver.sqlModeFor(), isNull, reason: "the server's mode");
    expect(MySqlDriver.sqlModeFor(strict: false), 'NO_ENGINE_SUBSTITUTION');
    expect(
      MySqlDriver.sqlModeFor(strict: true, version: '8.4.3'),
      '$strict,NO_ENGINE_SUBSTITUTION',
    );
    expect(
      MySqlDriver.sqlModeFor(strict: true, version: '11.4.2-MariaDB-ubu2404'),
      '$strict,NO_ENGINE_SUBSTITUTION',
      reason: 'version_compare sees MariaDB 10+ as newer than 8.0.11',
    );
    expect(
      MySqlDriver.sqlModeFor(strict: true, version: '5.7.44'),
      '$strict,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION',
    );
    expect(
      MySqlDriver.sqlModeFor(strict: true, modes: ['ANSI_QUOTES']),
      'ANSI_QUOTES',
      reason: 'modes win',
    );

    final driver = MySqlDriver.fromConfig(
      'mysql',
      const ConnectionConfig(
        driver: 'mysql',
        database: 'legacy',
        options: {
          'strict': 'false',
          'isolation_level': 'READ COMMITTED',
          'modes': null,
        },
      ),
    );
    expect(driver.strict, isFalse);
    expect(driver.sessionStatements('10.6.16-MariaDB'), [
      'SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED',
      "SET SESSION sql_mode='NO_ENGINE_SUBSTITUTION'",
    ]);
    expect(
      MySqlDriver.fromConfig(
        'mysql',
        const ConnectionConfig(
          driver: 'mysql',
          database: 'x',
          options: {'modes': 'STRICT_TRANS_TABLES, NO_ZERO_DATE'},
        ),
      ).modes,
      ['STRICT_TRANS_TABLES', 'NO_ZERO_DATE'],
    );
  });

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
    expect(driver.dialect, SqlDialect.mariadb);
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

  group('DB_SSLMODE and the CA (mysql_dart 4 verifies by default)', () {
    test('every mode that names verification verifies', () {
      for (final mode in [
        'verify-full',
        'VERIFY_IDENTITY',
        'verify_identity',
        'verify-ca',
        'VERIFY_CA',
        'verifyFull',
      ]) {
        final ssl = MySqlDriver.sslOptions(mode);
        expect(
          (ssl.secure, ssl.verify, ssl.warning),
          (true, true, null),
          reason: mode,
        );
      }
    });

    test('require and its MySQL names encrypt without checking', () {
      for (final mode in ['require', 'REQUIRED', 'prefer', 'PREFERRED']) {
        final ssl = MySqlDriver.sslOptions(mode);
        expect(
          (ssl.secure, ssl.verify, ssl.warning),
          (true, false, null),
          reason: mode,
        );
      }
    });

    test('disable and DISABLED turn TLS off, as an unset mode does', () {
      for (final mode in ['disable', 'DISABLED', null, '']) {
        final ssl = MySqlDriver.sslOptions(mode);
        expect((ssl.secure, ssl.verify), (false, false), reason: '$mode');
      }
    });

    test(
      'a CA without a mode verifies, as PDO MySQL with MYSQL_ATTR_SSL_CA',
      () {
        final ssl = MySqlDriver.sslOptions(null, ca: '/etc/ssl/db-ca.pem');
        expect((ssl.secure, ssl.verify), (true, true));
        expect(
          MySqlDriver.sslOptions('require', ca: '/etc/ssl/db-ca.pem').verify,
          isTrue,
          reason: 'require with a CA checks it, as libpq and the MySQL client',
        );
        expect(MySqlDriver.sslOptions('disable', ca: '/x.pem').secure, isFalse);
      },
    );

    test('an unknown mode is require, with one warning naming it', () {
      final warnings = <String>[];
      final driver = MySqlDriver.fromConfig(
        'mysql',
        const ConnectionConfig(
          driver: 'mysql',
          database: 'shop',
          options: {'sslmode': 'verify-fulll'},
        ),
        onWarning: warnings.add,
      );
      expect(driver.secure, isTrue);
      expect(driver.verifyServerCertificate, isFalse);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('"verify-fulll"'));
    });

    test('fromConfig passes the CA and the verification to the driver', () {
      final driver = MySqlDriver.fromConfig(
        'mysql',
        const ConnectionConfig(
          driver: 'mysql',
          database: 'shop',
          options: {'sslrootcert': '/etc/ssl/db-ca.pem'},
        ),
      );
      expect(driver.secure, isTrue);
      expect(driver.verifyServerCertificate, isTrue);
      expect(driver.sslCa, '/etc/ssl/db-ca.pem');
    });

    test('the constructor verifies by default, as mysql_dart 4', () {
      final driver = MySqlDriver(host: 'h', database: 'd', secure: true);
      expect(driver.verifyServerCertificate, isTrue);
      expect(driver.tlsContext(), isNull, reason: 'the system roots');
    });

    test(
      'DB_SSLROOTCERT, or Laravel MYSQL_ATTR_SSL_CA, reaches the options',
      () {
        ConnectionConfig mysql(Map<String, String> env) =>
            DatabaseConfig.fromEnv(
              Env.fromMap({'DB_CONNECTION': 'mysql', ...env}),
              basePath: '.',
            ).connections['mysql']!;
        expect(
          mysql({'MYSQL_ATTR_SSL_CA': '/a.pem'}).options['sslrootcert'],
          '/a.pem',
        );
        expect(
          mysql({'DB_SSLROOTCERT': '/b.pem', 'MYSQL_ATTR_SSL_CA': '/a.pem'})
              .options['sslrootcert'],
          '/b.pem',
        );
        expect(mysql({}).options['sslmode'], isNull);
      },
    );
  });

  test('DB_IDLE_TRANSACTION_TIMEOUT: MariaDB sets it, MySQL has none', () {
    MySqlDriver of(String driver, Map<String, Object?> options) =>
        MySqlDriver.fromConfig(
          driver,
          ConnectionConfig(driver: driver, database: 'x', options: options),
        );
    final mariadb = of('mariadb', const {'idle_transaction_timeout': '15'});
    expect(mariadb.idleTransactionTimeout, const Duration(seconds: 15));
    expect(mariadb.sessionStatements('11.4.2-MariaDB'), [
      'SET SESSION idle_transaction_timeout = 15',
    ]);
    final mysql = of('mysql', const {'idle_transaction_timeout': '15'});
    expect(mysql.idleTransactionTimeout, const Duration(seconds: 15));
    expect(mysql.sessionStatements('8.4.0'), isEmpty);
    expect(mysql.sessionStatements('11.4.2-MariaDB'), [
      'SET SESSION idle_transaction_timeout = 15',
    ], reason: 'a mysql connection on a MariaDB server');
    expect(of('mariadb', const {}).idleTransactionTimeout, isNull);
    expect(
      MySqlDriver(
        host: 'h',
        database: 'x',
        dialect: SqlDialect.mariadb,
        idleTransactionTimeout: const Duration(milliseconds: 1500),
      ).sessionStatements(null),
      ['SET SESSION idle_transaction_timeout = 2'],
      reason: 'whole seconds, rounded up',
    );
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

void shutdownTests() {
  test(
    'close() on a driver that never connected is a no-op; probes are bounded',
    () async {
      final driver = MySqlDriver(
        host: '127.0.0.1',
        // Nothing listens here: the probe fails within the bound.
        port: 1,
        database: 'd',
        connectTimeout: const Duration(milliseconds: 300),
      );
      expect(driver.inFlight, 0);
      expect(driver.drainTimeout, const Duration(seconds: 30));
      await driver.close();
      expect(driver.isConnected, isFalse);
      final watch = Stopwatch()..start();
      await expectLater(driver.connect(), throwsA(anything));
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason: 'connectTimeout plus the probe grace, not for ever',
      );
      expect(driver.isConnected, isFalse);
    },
  );
}
