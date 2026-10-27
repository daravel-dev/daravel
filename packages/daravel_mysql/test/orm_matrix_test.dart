@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

// The framework's database-independent suites, run here because only this
// package has the MySQL driver. Not published (.pubignore): the imports
// reach into the workspace.
import '../../daravel/test/broadcasting/scaling_test.dart' show scalingTests;
import '../../daravel/test/database/cache_store_concurrency_test.dart';
import '../../daravel/test/database/date_queries_and_guards_test.dart';
import '../../daravel/test/database/orm_polymorphic_test.dart';
import '../../daravel/test/database/orm_self_relations_and_aggregates_test.dart';
import '../../daravel/test/database/transaction_concurrency_test.dart';
import '../../daravel/test/features/feature_test.dart'
    show featureDatabaseTests;

/// Runs only when `DARAVEL_TEST_MYSQL` is set (CI: MySQL 8.4, MariaDB 11).
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (url == null || url.isEmpty) {
    test('ORM matrix (skipped: DARAVEL_TEST_MYSQL not set)', () {}, skip: true);
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  DatabaseManager open() => DatabaseManager(
    DatabaseConfig(
      defaultConnection: 'mysql',
      connections: {
        'mysql': ConnectionConfig(
          driver: 'mysql',
          database: uri.path.replaceFirst('/', ''),
          host: uri.host,
          port: uri.hasPort ? uri.port : 3306,
          username: user.first,
          password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
          options: const {'pool': 2},
        ),
      },
    ),
    drivers: const {'mysql': MySqlDriver.fromConfig},
  );

  group('polymorphic relations', () => polymorphicTests(open));
  group(
    'self relations and aggregates',
    () => selfRelationAndAggregateTests(open),
  );
  group('transaction concurrency', () => transactionConcurrencyTests(open));
  group('cache store concurrency', () => cacheStoreConcurrencyTests(open));
  group('date queries and guards', () => dateQueryAndGuardTests(open));
  group('feature flags (Pennant table)', () => featureDatabaseTests(open));
  group(
    'broadcast scaling',
    () => scalingTests(
      databaseUrl: url,
      configure: (builder) =>
          builder.withDatabaseDriver('mysql', MySqlDriver.fromConfig),
    ),
  );
}
