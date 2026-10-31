import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// `model:sync` promises a getter type for every column: this reads real
/// rows and checks the type against what the driver returns. Runs only when
/// `DARAVEL_TEST_PG` is set, as `postgres_integration_test.dart`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG'];
  if (url == null || url.isEmpty) {
    test('skipped: DARAVEL_TEST_PG not set', () {}, skip: true);
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  late DatabaseManager db;

  setUp(() {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'pgsql',
        connections: {
          'pgsql': ConnectionConfig(
            driver: 'pgsql',
            database: uri.path.replaceFirst('/', ''),
            host: uri.host,
            port: uri.port,
            username: user.first,
            password: user.last,
            options: const {'pool': 1, 'sslmode': 'disable'},
          ),
        },
      ),
    );
  });

  tearDown(() async {
    await db.statement('DROP TABLE IF EXISTS sync_types');
    await db.closeAll();
  });

  test('every getter type holds what the driver returns', () async {
    await db.statement('''
      CREATE TABLE sync_types (
        a_bool BOOLEAN NOT NULL, a_small SMALLINT NOT NULL, an_int INTEGER NOT NULL,
        a_big BIGINT NOT NULL, a_real REAL NOT NULL, a_double DOUBLE PRECISION NOT NULL,
        a_numeric NUMERIC(10,2) NOT NULL, a_varchar VARCHAR(20) NOT NULL,
        a_text TEXT NOT NULL, a_uuid UUID NOT NULL, a_date DATE NOT NULL,
        a_ts TIMESTAMP NOT NULL, a_tstz TIMESTAMPTZ NOT NULL, a_bytea BYTEA NOT NULL,
        a_time TIME NOT NULL, an_interval INTERVAL NOT NULL, an_inet INET NOT NULL,
        a_json JSON NOT NULL, a_jsonb JSONB NOT NULL, an_array INT[] NOT NULL
      )''');
    await db.statement('''
      INSERT INTO sync_types VALUES (
        TRUE, 1, 2, 3, 1.5, 2.5, 12.50, 'v', 't',
        '00000000-0000-0000-0000-000000000001', '2024-01-02',
        '2024-01-02 10:20:30', '2024-01-02 10:20:30+00', 'abc', '10:20:30',
        '1 day', '10.0.0.1', '{"a":1}', '{"a":1}', '{1,2}'
      )''');
    final schema = SchemaBuilder(await db.executor());
    final columns = await schema.getColumns('sync_types');
    final row = (await db.select('SELECT * FROM sync_types')).single;
    expect(columns, hasLength(20));
    for (final column in columns) {
      final type = dartTypeFor(column, null, dialect: SqlDialect.postgres).type;
      final value = row[column.name];
      final holds = switch (type) {
        'bool' => value is bool,
        'int' => value is int,
        'double' => value is double,
        'String' => value is String,
        'DateTime' => value is DateTime,
        'List<int>' => value is List<int>,
        'Object' => value != null,
        _ => false,
      };
      expect(
        holds,
        isTrue,
        reason:
            '${column.name} (${column.type}) is $type, the driver gives '
            '${value.runtimeType}',
      );
    }
    expect({
      for (final column in columns)
        column.name: dartTypeFor(
          column,
          null,
          dialect: SqlDialect.postgres,
        ).type,
    }, containsPair('a_ts', 'DateTime'));
  });
}
