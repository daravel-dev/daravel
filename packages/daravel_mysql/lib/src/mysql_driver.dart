import 'dart:async';
import 'dart:convert';
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
final class MySqlDriver
    implements DatabaseDriver, RetryableErrors, QueryErrors {
  MySqlDriver({
    required this.host,
    required this.database,
    this.port = 3306,
    this.username,
    this.password,
    this.name = 'mysql',
    this.maxConnections = 10,
    this.secure = false,
    this.collation = 'utf8mb4_unicode_ci',
    this.timeZone,
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout = const Duration(seconds: 30),
    this.strict,
    this.modes,
    this.isolationLevel,
    this.initCommands = const [],
    this.onConnectionOpen,
    this.dialect = SqlDialect.mysql,
  });

  /// Builds the driver from a connection of `config/database` (`DB_*`).
  ///
  /// `DB_SSLMODE` other than `disable` turns TLS on; without TLS the client
  /// may fetch the server's RSA key, which MySQL 8's default
  /// `caching_sha2_password` needs on a first login.
  factory MySqlDriver.fromConfig(String name, ConnectionConfig connection) {
    final sslMode = '${connection.options['sslmode'] ?? 'disable'}';
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
      secure: sslMode != 'disable',
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
    );
  }

  final String host;
  final int port;
  final String database;
  final String? username;
  final String? password;
  final int maxConnections;
  final bool secure;
  final String collation;
  final String? timeZone;
  final Duration connectTimeout;

  /// How long a statement may run (`DB_QUERY_TIMEOUT`, 30 s like
  /// PostgreSQL; `null` for none). Without it a statement stuck on a lock
  /// wait, a stalled replica or a half-open connection held its pooled
  /// connection for ever, and once `maxConnections` were stuck every
  /// request on the isolate queued behind them. On expiry `mysql_dart`
  /// issues `KILL QUERY` through a side connection.
  final Duration? queryTimeout;

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
      ...initCommands,
    ];
  }

  Future<void> _configure(my.MySQLConnection connection) async {
    String? version;
    if (strict == true && modes == null) {
      final result = await connection.execute('SELECT VERSION() AS v');
      version = result.rows.first.colByName('v') as String?;
    }
    for (final statement in sessionStatements(version)) {
      await connection.execute(statement);
    }
    await onConnectionOpen?.call(connection);
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
      collation: collation,
      timeoutMs: connectTimeout.inMilliseconds,
      allowPublicKeyRetrieval: !secure,
      timeZone: timeZone,
      onConnectionOpen: _configure,
    );
    try {
      // Fail fast on bad credentials or hosts instead of at the first query.
      // Bounded: mysql_dart opens its socket without a timeout, so a host
      // that accepts the TCP connection and never answers the handshake
      // would hold connect() for ever.
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

  Future<T> _withConnection<T>(
    Future<T> Function(my.MySQLConnection connection) body,
  ) async {
    final pool = _session;
    _inFlight++;
    try {
      final probe = PoolWaitProbe.current;
      if (probe == null) {
        return await pool.withConnection<T>(body);
      }
      final watch = Stopwatch()..start();
      return await pool.withConnection<T>((connection) {
        probe.waited = watch.elapsed;
        return body(connection);
      });
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _withConnection(
    (c) => _MySqlExecutor(c, queryTimeout, dialect).select(sql, bindings),
  );

  @override
  Future<int> execute(String sql, [List<Object?> bindings = const []]) =>
      _withConnection(
        (c) => _MySqlExecutor(c, queryTimeout, dialect).execute(sql, bindings),
      );

  @override
  Future<Object?> insertGetId(
    String sql, [
    List<Object?> bindings = const [],
  ]) => _withConnection(
    (c) => _MySqlExecutor(c, queryTimeout, dialect).insertGetId(sql, bindings),
  );

  @override
  Future<T> transaction<T>(Future<T> Function(QueryExecutor tx) body) =>
      _withConnection(
        (connection) => connection.transactional<T>(
          (tx) => body(_MySqlExecutor(tx, queryTimeout, dialect)),
        ),
      );
}

/// Runs statements on one connection (a pooled one, or a transaction's).
final class _MySqlExecutor implements QueryExecutor {
  _MySqlExecutor(this._connection, this._queryTimeout, this.dialect);

  final my.MySQLConnection _connection;
  final Duration? _queryTimeout;

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

  Future<my.IResultSet> _run(String sql, List<Object?> bindings) =>
      _connection.execute(sql, _normalize(bindings), false, _queryTimeout);

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
