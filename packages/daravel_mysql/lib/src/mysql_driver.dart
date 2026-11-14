import 'dart:async';
import 'dart:convert';
import 'dart:io' show SecurityContext, stderr;
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:mysql_dart/exception.dart';
import 'package:mysql_dart/mysql_dart.dart' as my;

/// MySQL and MariaDB driver (ADR-019), on the pure Dart `mysql_dart` client.
///
/// Register it in `bootstrap/app.dart`:
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
///     .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
/// ```
///
/// Queries with bindings run as server-side prepared statements (cached per
/// connection), so values never reach the SQL text. Values are read as
/// Laravel reads them: dates and times as `Y-m-d H:i:s` strings, which the
/// ORM parses as UTC. The session time zone is left to the server unless
/// `DB_TIMEZONE` is set, as in Laravel, so `TIMESTAMP` columns read the same
/// from both applications.
///
/// Pool connections opened on demand: the first connection is opened
/// detached (`DatabaseManager`, Review #149), but a further connection the
/// pool opens under load is opened by the query that needed it, in that
/// query's zone (a request's, a job's). The driver touches neither the
/// container nor the log on that path, so no request scope or `request_id`
/// is kept by the connection; an error its socket raises later that the
/// client package leaves unhandled would reach that zone's error handler.
final class MySqlDriver
    implements
        SessionTerminatingDriver,
        RetryableErrors,
        QueryErrors,
        DataExceptionErrors {
  /// A pooled MySQL or MariaDB connection; usually made by
  /// [MySqlDriver.fromConfig] from the `DB_*` settings.
  MySqlDriver({
    required this.host,
    required this.database,
    this.port = 3306,
    this.username,
    this.password,
    this.name = 'mysql',
    this.maxConnections = 10,
    this.secure = false,
    this.verifyServerCertificate = true,
    this.securityContext,
    this.sslCa,
    this.collation = 'utf8mb4_unicode_ci',
    this.timeZone,
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout = const Duration(seconds: 30),
    this.strict,
    this.modes,
    this.isolationLevel,
    this.initCommands = const [],
    this.onConnectionOpen,
    this.idleTransactionTimeout,
    this.dialect = SqlDialect.mysql,
    this.statementTimeoutMode = StatementTimeoutMode.server,
    this.onWarning,
  });

  /// Builds the driver from a connection of `config/database` (`DB_*`).
  ///
  /// TLS follows `DB_SSLMODE` as [sslOptions] reads it, with the CA of
  /// `DB_SSLROOTCERT` (or Laravel's `MYSQL_ATTR_SSL_CA`). Without TLS the
  /// client may fetch the server's RSA key, which MySQL 8's default
  /// `caching_sha2_password` needs on a first login. An unknown
  /// `DB_SSLMODE` is reported once, at boot, through [onWarning] (standard
  /// error by default).
  factory MySqlDriver.fromConfig(
    String name,
    ConnectionConfig connection, {
    void Function(String message)? onWarning,
  }) {
    final ca = switch (connection.options['sslrootcert']) {
      final String path when path.isNotEmpty => path,
      _ => null,
    };
    final ssl = sslOptions(connection.options['sslmode'], ca: ca);
    if (ssl.warning case final warning?) {
      final void Function(String) warn = onWarning ?? stderr.writeln;
      warn('[$name] $warning');
    }
    return MySqlDriver(
      name: name,
      dialect: connection.driver == 'mariadb'
          ? SqlDialect.mariadb
          : SqlDialect.mysql,
      host: connection.host ?? '127.0.0.1',
      port: connection.port ?? 3306,
      database: connection.database,
      username: connection.username,
      password: connection.password,
      maxConnections: (connection.options['pool'] as int?) ?? 10,
      secure: ssl.secure,
      verifyServerCertificate: ssl.verify,
      sslCa: ca,
      onWarning: onWarning,
      collation:
          (connection.options['collation'] as String?) ?? 'utf8mb4_unicode_ci',
      timeZone: connection.options['timezone'] as String?,
      connectTimeout:
          PostgresDriver.timeoutOption(
            connection.options['connect_timeout'],
            const Duration(seconds: 10),
          ) ??
          PostgresDriver.noTimeout,
      queryTimeout: PostgresDriver.timeoutOption(
        connection.options['query_timeout'],
        const Duration(seconds: 30),
      ),
      strict: switch (connection.options['strict']) {
        final bool value => value,
        'true' || '1' => true,
        'false' || '0' => false,
        _ => null,
      },
      modes: switch (connection.options['modes']) {
        final List<Object?> list => [for (final m in list) '$m'],
        final String text when text.trim().isNotEmpty => [
          for (final m in text.split(',')) m.trim(),
        ],
        _ => null,
      },
      isolationLevel: connection.options['isolation_level'] as String?,
      idleTransactionTimeout: PostgresDriver.idleTransactionTimeoutOption(
        connection.options['idle_transaction_timeout'],
      ),
      statementTimeoutMode:
          switch (connection.options['statement_timeout_mode']) {
            'client' => StatementTimeoutMode.client,
            _ => StatementTimeoutMode.server,
          },
    );
  }

  /// The server host.
  final String host;

  /// The server port (3306).
  final int port;

  /// The database name.
  final String database;

  /// The user name.
  final String? username;

  /// The password.
  final String? password;

  /// The most connections the pool opens.
  final int maxConnections;

  /// Whether TLS is used.
  final bool secure;

  /// With [secure], whether the server certificate must chain to a trusted
  /// root ([securityContext], [sslCa], or the system roots) and name
  /// [host]. `false` keeps the traffic encrypted but accepts any
  /// certificate, which does not stop an active attacker. True by default,
  /// as in `mysql_dart` 4.
  final bool verifyServerCertificate;

  /// The trusted roots for [verifyServerCertificate]; the system roots
  /// (plus [sslCa]) when null.
  final SecurityContext? securityContext;

  /// A PEM file of the CA that signed the server certificate
  /// (`DB_SSLROOTCERT`, `MYSQL_ATTR_SSL_CA`), trusted beside the system
  /// roots when [securityContext] is null.
  final String? sslCa;

  /// How `DB_SSLMODE` (any case, `-` or `_`) and a CA map to TLS, the same
  /// as the PostgreSQL driver and libpq, with MySQL's `--ssl-mode` names:
  ///
  /// - `disable`, `disabled`: no TLS.
  /// - `require`, `required`, `prefer`, `preferred`, `allow`: TLS without
  ///   checking the certificate (encrypted, but open to an active
  ///   attacker); with a [ca], checked, as libpq and the MySQL client do.
  /// - `verify-full`, `verify-identity`, `verify-ca`: TLS with the
  ///   certificate checked against the CA and the host name. `verify-ca` is
  ///   checked as strictly: `dart:io` reports a bad chain and a wrong host
  ///   name through the same callback, so the host cannot be left out.
  /// - empty: no TLS, or checked TLS when a [ca] is given, as PDO MySQL
  ///   (mysqlnd) verifies the server when `MYSQL_ATTR_SSL_CA` is set.
  /// - another value starting with `verify` (a misspelt `verify-full`):
  ///   checked, with a [warning] naming the value. A typo must not weaken
  ///   the check it asked for.
  /// - anything else: as `require`, with a [warning] naming the value.
  static ({bool secure, bool verify, String? warning}) sslOptions(
    Object? sslmode, {
    String? ca,
  }) {
    final mode = '${sslmode ?? ''}'.trim().toLowerCase().replaceAll('_', '-');
    final hasCa = ca != null && ca.isNotEmpty;
    return switch (mode) {
      '' => (secure: hasCa, verify: hasCa, warning: null),
      'disable' || 'disabled' => (secure: false, verify: false, warning: null),
      'require' ||
      'required' ||
      'prefer' ||
      'preferred' ||
      'allow' => (secure: true, verify: hasCa, warning: null),
      'verify-full' ||
      'verifyfull' ||
      'verify-identity' ||
      'verify-ca' => (secure: true, verify: true, warning: null),
      _ when mode.startsWith('verify') => (
        secure: true,
        verify: true,
        warning:
            'DB_SSLMODE "$sslmode" is not a known mode; using "verify-full" '
            '(TLS with the certificate and host name checked).',
      ),
      _ => (
        secure: true,
        verify: hasCa,
        warning:
            'DB_SSLMODE "$sslmode" is not a known mode; using "require" '
            '(TLS without certificate checks). Use disable, require or '
            'verify-full.',
      ),
    };
  }

  /// The connection collation (`utf8mb4_unicode_ci`).
  final String collation;

  /// The session time zone; the server's when null.
  final String? timeZone;

  /// How long to wait for a connection.
  final Duration connectTimeout;

  /// How long a statement may run (`DB_QUERY_TIMEOUT`, 30 s like
  /// PostgreSQL; `null` for none). Without it a statement stuck on a lock
  /// wait, a stalled replica or a half-open connection held its pooled
  /// connection for ever, and once `maxConnections` were stuck every
  /// request on the isolate queued behind them. [statementTimeoutMode]
  /// says who enforces it.
  final Duration? queryTimeout;

  /// Where [queryTimeout] is enforced (#156). [StatementTimeoutMode.server],
  /// the default: each pooled connection sets `max_execution_time` (MySQL
  /// 5.7.8+, `SELECT` statements only) or `max_statement_time` (MariaDB
  /// 10.1+, every statement) once, and the server stops a statement past
  /// it with error 3024 or 1969, thrown as [StatementTimeoutException],
  /// without a second connection. Outside a transaction a client backstop
  /// ([backstopGrace] later) closes a connection that still has not
  /// answered; inside one only the server bounds the statement, since a
  /// `ROLLBACK` would queue behind it. [StatementTimeoutMode.client] keeps
  /// the timeout of `mysql_dart` (`KILL QUERY` through a side connection);
  /// the driver falls back to it, with one [onWarning], when the server
  /// refuses `SET SESSION` (error 1227) or does not know the variable.
  final StatementTimeoutMode statementTimeoutMode;

  /// Told once when server-side timeouts fall back to the client; stderr
  /// when null.
  final void Function(String message)? onWarning;

  /// Added to [queryTimeout] for the client backstop of server mode.
  static const Duration backstopGrace = Duration(seconds: 5);

  /// False once the server refused the session timeout variable.
  bool _serverTimeouts = true;
  bool _warned = false;

  /// The server's `VERSION()`, read once by the first connection that
  /// needs it (strict sql_mode, the session timeout, MariaDB detection).
  String? _version;

  /// Whether statements are bounded by the server right now.
  bool get serverSideTimeouts =>
      statementTimeoutMode == StatementTimeoutMode.server &&
      _serverTimeouts &&
      (queryTimeout ?? Duration.zero) > Duration.zero;

  /// The statement setting [timeout] for the session on a server of
  /// [version] (MariaDB when it says so, or for a `mariadb` connection).
  static String sessionTimeoutStatement(
    Duration timeout, {
    required String? version,
    SqlDialect dialect = SqlDialect.mysql,
  }) {
    if (isMariaDb(version, dialect)) {
      final seconds = timeout.inMicroseconds / Duration.microsecondsPerSecond;
      return 'SET SESSION max_statement_time = $seconds';
    }
    return 'SET SESSION max_execution_time = ${timeout.inMilliseconds}';
  }

  /// The statement bounding a row-lock wait by [timeout], in whole seconds
  /// (at least 1, the variable's minimum). `max_execution_time` bounds only
  /// `SELECT`, and the client backstop is off inside a transaction, so
  /// without it an `UPDATE` waiting for a row lock there waited for the
  /// server's `innodb_lock_wait_timeout` (50 s by default) whatever
  /// `DB_QUERY_TIMEOUT` said. The wait ends with error 1205, which
  /// `transaction(attempts:)` retries ([isRetryableError]).
  static String lockWaitStatement(Duration timeout) {
    final seconds = (timeout.inMilliseconds / 1000).ceil();
    return 'SET SESSION innodb_lock_wait_timeout = ${seconds < 1 ? 1 : seconds}';
  }

  /// `ER_QUERY_TIMEOUT` of MySQL (3024) and `ER_STATEMENT_TIMEOUT` of
  /// MariaDB (1969): the server stopped a statement past its time.
  static bool isTimeoutCode(int code) => code == 3024 || code == 1969;

  /// Laravel's `'strict'` (`DB_STRICT`): `true` sets the strict
  /// `sql_mode` Laravel sets, `false` sets `NO_ENGINE_SUBSTITUTION` (no
  /// strict mode: a missing `NOT NULL` value becomes `''` or `0` as the
  /// server allows), `null` leaves the server's mode. A Laravel
  /// application's `config/database.php` usually has `'strict' => true`.
  final bool? strict;

  /// Laravel's `'modes'` (`DB_SQL_MODES`): an explicit `sql_mode`, over
  /// [strict].
  final List<String>? modes;

  /// Laravel's `'isolation_level'` (`DB_ISOLATION_LEVEL`), e.g.
  /// `READ COMMITTED`.
  final String? isolationLevel;

  /// MariaDB's `idle_transaction_timeout` (10.3+) for every connection of
  /// the pool (`DB_IDLE_TRANSACTION_TIMEOUT`, whole seconds, rounded up), on
  /// a `mariadb` connection or a server whose `VERSION()` says MariaDB:
  /// the server closes a connection that stays idle inside a transaction
  /// this long, rolling it back. MySQL has no such setting and ignores it
  /// (its `wait_timeout` closes idle connections outside transactions too).
  /// `null` keeps the server's setting.
  final Duration? idleTransactionTimeout;

  /// MySQL connection ids of the pool's open connections, for [sessionIds].
  final Map<my.MySQLConnection, int> _sessions = <my.MySQLConnection, int>{};

  /// Statements run on every new connection, after the session settings.
  final List<String> initCommands;

  /// Runs on every new connection of the pool, last.
  final FutureOr<void> Function(my.MySQLConnection connection)?
  onConnectionOpen;

  /// The `sql_mode` Laravel 12's `MySqlConnector::getSqlMode` sets for
  /// [strict] and [modes] on a server of [version] (`null`: none).
  static String? sqlModeFor({
    bool? strict,
    List<String>? modes,
    String? version,
  }) {
    if (modes != null) {
      return modes.join(',');
    }
    if (strict == null) {
      return null;
    }
    if (!strict) {
      return 'NO_ENGINE_SUBSTITUTION';
    }
    const base =
        'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,'
        'NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO';
    // MySQL 8.0.11 removed NO_AUTO_CREATE_USER; PHP's version_compare sees
    // MariaDB 10+ as newer too.
    return _atLeast(version ?? '0', const [8, 0, 11])
        ? '$base,NO_ENGINE_SUBSTITUTION'
        : '$base,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
  }

  static bool _atLeast(String version, List<int> wanted) {
    final parts = [
      for (final part in RegExp(r'\d+').allMatches(version).take(3))
        int.parse(part.group(0)!),
    ];
    for (var i = 0; i < wanted.length; i++) {
      final have = i < parts.length ? parts[i] : 0;
      if (have != wanted[i]) {
        return have > wanted[i];
      }
    }
    return true;
  }

  /// The session settings for a new connection to a server of [version].
  List<String> sessionStatements(String? version) {
    final mode = sqlModeFor(strict: strict, modes: modes, version: version);
    return [
      if (isolationLevel != null)
        'SET SESSION TRANSACTION ISOLATION LEVEL $isolationLevel',
      if (mode != null) "SET SESSION sql_mode='$mode'",
      if (idleTransactionTimeout case final idle?
          when isMariaDb(version, dialect))
        'SET SESSION idle_transaction_timeout = '
            '${(idle.inMilliseconds / 1000).ceil()}',
      ...initCommands,
    ];
  }

  /// Whether a server of [version] is MariaDB: a `mariadb` connection, or a
  /// `mysql` one whose `VERSION()` says so.
  static bool isMariaDb(String? version, SqlDialect dialect) =>
      dialect == SqlDialect.mariadb ||
      (version ?? '').toLowerCase().contains('mariadb');

  Future<void> _configure(my.MySQLConnection connection) async {
    final timeout = queryTimeout;
    final serverTimeout = serverSideTimeouts && timeout != null;
    // One VERSION() read for every need: the strict sql_mode, the server
    // side statement timeout, and whether a `mysql` connection is MariaDB
    // (its idle_transaction_timeout).
    if (_version == null &&
        ((strict == true && modes == null) ||
            serverTimeout ||
            (idleTransactionTimeout != null &&
                dialect != SqlDialect.mariadb))) {
      final result = await connection.execute('SELECT VERSION() AS v');
      _version = result.rows.first.colByName('v') as String?;
    }
    if (timeout != null && timeout > Duration.zero) {
      // Before sessionStatements, so an initCommand of the application
      // that sets its own lock wait wins.
      try {
        await connection.execute(lockWaitStatement(timeout));
      } on MySQLServerException catch (error) {
        // 1227: no privilege; 1193: unknown variable (no InnoDB).
        if (error.errorCode != 1227 && error.errorCode != 1193) {
          rethrow;
        }
      }
    }
    for (final statement in sessionStatements(_version)) {
      await connection.execute(statement);
    }
    if (serverTimeout) {
      try {
        await connection.execute(
          sessionTimeoutStatement(timeout, version: _version, dialect: dialect),
        );
      } on MySQLServerException catch (error) {
        // 1227: no privilege; 1193: unknown variable (an older server).
        if (error.errorCode != 1227 && error.errorCode != 1193) {
          rethrow;
        }
        _serverTimeouts = false;
        if (!_warned) {
          _warned = true;
          final void Function(String) warn = onWarning ?? stderr.writeln;
          warn(
            'MySQL connection [$name]: the server refused the session '
            'statement timeout ($error); DB_QUERY_TIMEOUT is enforced by the '
            'client instead (KILL QUERY through a second connection).',
          );
        }
      }
    }
    await onConnectionOpen?.call(connection);
    final result = await connection.execute('SELECT CONNECTION_ID() AS id');
    _sessions[connection] = int.parse('${result.rows.first.colByName('id')}');
    connection.onClose(() => _sessions.remove(connection));
  }

  @override
  List<String> sessionIds() => [
    for (final entry in _sessions.entries)
      if (entry.key.connected) '${entry.value}',
  ];

  /// `KILL CONNECTION` of [id], from another connection of the pool;
  /// `false` for an id the server does not know (`ER_NO_SUCH_THREAD`).
  @override
  Future<bool> terminateSession(String id) async {
    final connectionId = int.tryParse(id);
    if (connectionId == null) {
      return false;
    }
    try {
      await execute('KILL CONNECTION $connectionId');
      return true;
    } on MySQLServerException catch (error) {
      if (error.errorCode == 1094) {
        return false;
      }
      rethrow;
    }
  }

  @override
  final String name;

  my.MySQLConnectionPool? _pool;

  /// [SqlDialect.mariadb] for a `mariadb` connection, for what MariaDB adds.
  @override
  final SqlDialect dialect;

  @override
  bool get isConnected => _pool != null;

  /// MySQL errors worth retrying a whole transaction for: deadlock (1213)
  /// and lock wait timeout (1205).
  @override
  bool isRetryableError(Object error) =>
      error is MySQLServerException &&
      (error.errorCode == 1213 || error.errorCode == 1205);

  /// `ER_DUP_ENTRY` (1062), as Laravel matches "Integrity constraint
  /// violation: 1062".
  @override
  bool isUniqueConstraintError(Object error) =>
      error is MySQLServerException && error.errorCode == 1062;

  /// The server refusing a value as its column's or expression's type:
  /// out of range (1264, 1690), a truncated incorrect value (1292, a
  /// `CAST` of text that is not a number in strict mode), an incorrect
  /// value (1366) and data too long (1406).
  @override
  bool isDataException(Object error) =>
      error is MySQLServerException &&
      const {1264, 1292, 1366, 1406, 1690}.contains(error.errorCode);

  /// The roots the server certificate is checked against: [securityContext],
  /// or the system roots plus [sslCa]; null (the system roots) without
  /// either. A CA file that cannot be read throws a [StateError] naming the
  /// connection, the path and the settings it comes from.
  SecurityContext? tlsContext() {
    final ca = sslCa;
    if (securityContext != null || ca == null) {
      return securityContext;
    }
    try {
      return SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(ca);
    } on Object catch (error) {
      throw StateError(
        'MySQL connection [$name]: cannot read the CA file "$ca" '
        '(DB_SSLROOTCERT or MYSQL_ATTR_SSL_CA): $error',
      );
    }
  }

  @override
  Future<void> connect() async {
    if (_pool != null) {
      return;
    }
    final pool = my.MySQLConnectionPool(
      host: host,
      port: port,
      userName: username ?? 'root',
      password: password ?? '',
      maxConnections: maxConnections,
      databaseName: database,
      secure: secure,
      verifyServerCertificate: verifyServerCertificate,
      securityContext: tlsContext(),
      collation: collation,
      timeoutMs: connectTimeout.inMilliseconds,
      allowPublicKeyRetrieval: !secure,
      timeZone: timeZone,
      onConnectionOpen: _configure,
    );
    try {
      // Fail fast on bad credentials or hosts instead of at the first query.
      // Bounded: mysql_dart 3 opened its socket without a timeout; 4 bounds
      // the TCP connect, TLS and authentication with timeoutMs, and this
      // stays as a second guard until the 4.x follow-up review.
      await pool.execute('SELECT 1').timeout(connectTimeout + probeGrace);
    } catch (_) {
      await pool.close();
      rethrow;
    }
    _pool = pool;
  }

  /// Added to [connectTimeout] for the `SELECT 1` probe of [connect].
  static const Duration probeGrace = Duration(seconds: 5);

  /// Statements running on the pool right now ([close] waits for them).
  int get inFlight => _inFlight;
  int _inFlight = 0;

  /// How long [close] waits for in-flight statements before closing the
  /// pool under them: `mysql_dart`'s pool close never completes the
  /// callers still queued for a connection, so draining first keeps a
  /// graceful shutdown from hanging on them.
  Duration get drainTimeout => queryTimeout ?? const Duration(seconds: 30);

  @override
  Future<void> close() async {
    final pool = _pool;
    _pool = null;
    if (pool == null) {
      return;
    }
    final deadline = DateTime.now().add(drainTimeout);
    while (_inFlight > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await pool.close();
  }

  my.MySQLConnectionPool get _session {
    final pool = _pool;
    if (pool == null) {
      throw StateError(
        'MySQL connection [$name] is not open; call connect() first.',
      );
    }
    return pool;
  }

  /// Runs [body] on a pooled connection, waiting at most [connectTimeout]
  /// for one: `mysql_dart`'s pool queues callers without a bound, so a pool
  /// held by long transactions would make every request wait for ever. A
  /// caller that gives up gets a [PoolExhaustedException]; the connection
  /// the pool hands it later goes straight back.
  Future<T> _withConnection<T>(
    Future<T> Function(my.MySQLConnection connection) body, {
    String sql = '',
    List<Object?> bindings = const [],
  }) async {
    final pool = _session;
    _inFlight++;
    try {
      final probe = PoolWaitProbe.current;
      final watch = Stopwatch()..start();
      var acquired = false;
      var abandoned = false;
      final result = Completer<T>();
      final timer = Timer(connectTimeout, () {
        if (acquired || result.isCompleted) {
          return;
        }
        abandoned = true;
        result.completeError(
          PoolExhaustedException(
            name,
            watch.elapsed,
            sql: sql,
            bindings: bindings,
          ),
          StackTrace.current,
        );
      });
      final work = Future<Object?>.sync(
        () => pool.withConnection<Object?>((connection) {
          if (abandoned) {
            return null;
          }
          acquired = true;
          probe?.waited = watch.elapsed;
          return body(connection);
        }),
      );
      unawaited(
        work.then(
          (value) {
            timer.cancel();
            if (!result.isCompleted) {
              result.complete(value as T);
            }
          },
          onError: (Object error, StackTrace stack) {
            timer.cancel();
            if (!result.isCompleted) {
              result.completeError(error, stack);
            }
          },
        ),
      );
      return await result.future;
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _withConnection(
    (c) => _executor(c).select(sql, bindings),
    sql: sql,
    bindings: bindings,
  );

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) =>
      _withConnection(
        (c) => _executor(c).execute(sql, bindings),
        sql: sql,
        bindings: bindings,
      );

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _withConnection(
    (c) => _executor(c).insertGetId(sql, bindings),
    sql: sql,
    bindings: bindings,
  );

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _withConnection(
        (connection) => connection.transactional<T>(
          (tx) => body(_executor(tx, inTransaction: true)),
        ),
      );

  _MySqlExecutor _executor(
    my.MySQLConnection connection, {
    bool inTransaction = false,
  }) => _MySqlExecutor(
    connection,
    queryTimeout,
    dialect,
    serverSide: serverSideTimeouts,
    inTransaction: inTransaction,
  );
}

/// Runs statements on one connection (a pooled one, or a transaction's).
final class _MySqlExecutor implements QueryExecutor {
  _MySqlExecutor(
    this._connection,
    this._queryTimeout,
    this.dialect, {
    this.serverSide = false,
    this.inTransaction = false,
  });

  final my.MySQLConnection _connection;
  final Duration? _queryTimeout;

  /// The server bounds statements (`max_execution_time`).
  final bool serverSide;

  /// Inside a transaction: no client backstop (a ROLLBACK would wait).
  final bool inTransaction;

  @override
  final SqlDialect dialect;

  /// Prepared-statement parameters in the form MySQL stores what Laravel
  /// writes.
  static List<Object?>? _normalize(List<Object?> bindings) => bindings.isEmpty
      ? null
      : [
          for (final value in bindings)
            switch (value) {
              bool() => value ? 1 : 0,
              DateTime() => formatDateTime(value),
              Enum() => value.name,
              Map<Object?, Object?>() ||
              List<Object?>() => value is Uint8List ? value : jsonEncode(value),
              _ => value,
            },
        ];

  Future<my.IResultSet> _run(String sql, List<Object?> bindings) async {
    final timeout = _queryTimeout;
    if (!serverSide || timeout == null) {
      return _connection.execute(sql, _normalize(bindings), false, timeout);
    }
    var running = _connection.execute(sql, _normalize(bindings), false, null);
    if (!inTransaction) {
      final limit = timeout + MySqlDriver.backstopGrace;
      running = running.timeout(
        limit,
        onTimeout: () {
          // The server did not stop it (an UPDATE on MySQL, which bounds
          // only SELECT, or a connection that stopped answering): close this
          // connection, which the pool then replaces, rather than a KILL
          // through a second one.
          _connection.getSocket().destroy();
          throw StatementTimeoutException(
            'Statement still running $limit after it started; the '
            'connection was closed.',
            timeout: timeout,
          );
        },
      );
    }
    try {
      return await running;
    } on MySQLServerException catch (error) {
      if (MySqlDriver.isTimeoutCode(error.errorCode)) {
        throw StatementTimeoutException(
          error.message,
          code: error.errorCode,
          timeout: timeout,
        );
      }
      rethrow;
    }
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) async {
    final result = await _run(sql, bindings);
    final columns = result.cols.toList(growable: false);
    final names = [for (final column in columns) column.name];
    final readers = [for (final column in columns) _reader(column)];
    return [for (final row in result.rows) _row(row, names, readers)];
  }

  /// A row as Laravel reads it: numbers as numbers, TINYINT(1) as 0/1 (not
  /// bool), and dates and times as the server's `Y-m-d H:i:s` text rather
  /// than a local-time `DateTime` (the ORM parses them as UTC).
  ///
  /// One pass over the values with the column's [_reader]. It replaced
  /// `assoc()` + `typedAssoc()` + a third map per row, which parsed every
  /// DATETIME into a `DateTime` only to read the text back and built three
  /// 40-entry maps per row: half of the time a 1 000 x 40 result took.
  static Map<String, Object?> _row(
    my.ResultSetRow row,
    List<String> names,
    List<_Reader?> readers,
  ) {
    final values = <String, Object?>{};
    for (var i = 0; i < names.length; i++) {
      final Object? value = row.colAt(i);
      final reader = readers[i];
      values[names[i]] = reader == null || value is! String
          ? value
          : reader(value);
    }
    return values;
  }

  /// How the text of [column] is read, or `null` to keep it as it comes
  /// (strings, decimals, JSON, bytes). Both protocols deliver these types as
  /// text: `mysql_dart` formats binary-protocol numbers and dates too.
  static _Reader? _reader(my.ResultSetColumn column) =>
      switch (column.type.intVal) {
        // TINYINT(1) is a boolean to mysql_dart; Laravel reads 0/1.
        0x01 when column.length == 1 => (text) => int.parse(text) > 0 ? 1 : 0,
        // TINY, SHORT, LONG, LONGLONG, INT24, YEAR; BIGINT UNSIGNED above
        // 2^63 - 1 does not fit a Dart int.
        0x01 ||
        0x02 ||
        0x03 ||
        0x08 ||
        0x09 ||
        0x0d => (text) => int.tryParse(text) ?? BigInt.parse(text),
        // FLOAT, DOUBLE.
        0x04 || 0x05 => double.parse,
        // DATE and NEWDATE: the binary protocol decoder adds a midnight time
        // that Laravel never sees.
        0x0a || 0x0e =>
          (text) => !_representableDate(text)
              ? null
              : text.length > 10
              ? text.substring(0, 10)
              : text,
        // TIMESTAMP, DATETIME, TIMESTAMP2, DATETIME2.
        0x07 ||
        0x0c ||
        0x11 ||
        0x12 => (text) => _representableDate(text) ? text : null,
        _ => null,
      };

  /// Whether the date in [text] (`Y-m-d`, with or without a time) is one a
  /// `DateTime` can represent. The zero date `0000-00-00`, a zero month or
  /// day and an invalid day (`2024-02-30` under ALLOW_INVALID_DATES) read as
  /// null, as `mysql_dart`'s `ZeroDateBehavior.convertToNull` did. Text in
  /// another form is kept as it is.
  static bool _representableDate(String text) {
    if (text.length < 10) {
      return true;
    }
    final year = _digits(text, 0, 4);
    final month = _digits(text, 5, 7);
    final day = _digits(text, 8, 10);
    if (year < 0 || month < 0 || day < 0) {
      return true;
    }
    if (month < 1 || month > 12 || day < 1) {
      return false;
    }
    final int daysInMonth;
    if (month == 2) {
      final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
      daysInMonth = leap ? 29 : 28;
    } else {
      daysInMonth = const [
        31,
        0,
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
      ][month - 1];
    }
    return day <= daysInMonth;
  }

  /// The decimal number in `text[start, end)`, or -1 for a non-digit.
  static int _digits(String text, int start, int end) {
    var value = 0;
    for (var i = start; i < end; i++) {
      final digit = text.codeUnitAt(i) - 0x30;
      if (digit < 0 || digit > 9) {
        return -1;
      }
      value = value * 10 + digit;
    }
    return value;
  }

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) async =>
      (await _run(sql, bindings)).affectedRows.toInt();

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) async {
    final id = (await _run(sql, bindings)).lastInsertID;
    return id == BigInt.zero ? null : id.toInt();
  }
}

/// Reads a column's text into the value Laravel sees.
typedef _Reader = Object? Function(String text);

/// Where `DB_QUERY_TIMEOUT` is enforced on MySQL and MariaDB
/// ([MySqlDriver.statementTimeoutMode]).
enum StatementTimeoutMode {
  /// By the server (`max_execution_time` / `max_statement_time`), with a
  /// client backstop outside transactions.
  server,

  /// By the client, as before: `mysql_dart` sends `KILL QUERY` through a
  /// second connection.
  client,
}

/// A statement stopped for running past `DB_QUERY_TIMEOUT`: by the server
/// ([code] 3024 on MySQL, 1969 on MariaDB) or by the client backstop
/// ([code] null, the connection closed). It reaches the application as the
/// [QueryException.previous] of the failed query, and is never retried.
final class StatementTimeoutException implements Exception {
  /// A statement that ran past [timeout].
  const StatementTimeoutException(this.message, {this.code, this.timeout});

  /// What the server (or the backstop) said.
  final String message;

  /// The server's error code, or null for the client backstop.
  final int? code;

  /// The configured `DB_QUERY_TIMEOUT`.
  final Duration? timeout;

  @override
  String toString() =>
      'StatementTimeoutException${code == null ? '' : ' [$code]'}: $message';
}
