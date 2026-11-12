import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// `Schema.getForeignKeys` on MySQL or MariaDB (`DARAVEL_TEST_MYSQL`):
/// Laravel 13's `MySqlGrammar::compileForeignKeys` in the current database,
/// the actions in lower case as its `MySqlProcessor` gives them.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];

  test('names, columns in order, actions', () async {
    final uri = Uri.parse(url!);
    final user = uri.userInfo.split(':');
    final base = Directory.systemTemp.createTempSync('daravel_mysql_fk');
    addTearDown(() => base.deleteSync(recursive: true));
    final app = Application.configure(basePath: base.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'mysql',
          'DB_HOST': uri.host,
          'DB_PORT': '${uri.port}',
          'DB_DATABASE': uri.path.replaceFirst('/', ''),
          'DB_USERNAME': user.first,
          'DB_PASSWORD': user[1],
        })
        .withLogLevel(LogLevel.critical)
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      for (final table in [
        'fk_grades',
        'fk_sessions',
        'fk_pairs',
        'fk_assessments',
        'fk_users',
      ]) {
        await Schema.dropIfExists(table);
      }
      for (final sql in [
        'create table fk_users (id bigint primary key) engine=InnoDB',
        'create table fk_assessments (id bigint primary key) engine=InnoDB',
        'create table fk_pairs (a bigint, b bigint, primary key (a, b)) '
            'engine=InnoDB',
        'create table fk_sessions (id bigint primary key, '
            'assessment_id bigint not null, user_id bigint, parent_id bigint, '
            'constraint fk_sessions_assessment foreign key (assessment_id) '
            'references fk_assessments (id) on delete cascade, '
            'constraint fk_sessions_user foreign key (user_id) '
            'references fk_users (id) on delete set null on update cascade, '
            'constraint fk_sessions_parent foreign key (parent_id) '
            'references fk_sessions (id)) engine=InnoDB',
        'create table fk_grades (id bigint primary key, s bigint, t bigint, '
            'constraint fk_grades_pair foreign key (s, t) '
            'references fk_pairs (a, b) on delete restrict) engine=InnoDB',
      ]) {
        await DB.statement(sql);
      }
      final sessions = {
        for (final key in await Schema.getForeignKeys('fk_sessions'))
          key.name: key,
      };
      expect(sessions.keys.toSet(), {
        'fk_sessions_assessment',
        'fk_sessions_user',
        'fk_sessions_parent',
      });
      final userKey = sessions['fk_sessions_user']!;
      expect(userKey.columns, ['user_id']);
      expect(userKey.foreignTable, 'fk_users');
      expect(userKey.foreignColumns, ['id']);
      expect(userKey.onUpdate, 'cascade');
      expect(userKey.onDelete, 'set null');
      expect(sessions['fk_sessions_assessment']!.onDelete, 'cascade');
      expect(sessions['fk_sessions_parent']!.foreignTable, 'fk_sessions');
      final pair = (await Schema.getForeignKeys('fk_grades')).single;
      expect(pair.columns, ['s', 't']);
      expect(pair.foreignColumns, ['a', 'b']);
      expect(pair.onDelete, 'restrict');
      expect(await Schema.getForeignKeys('fk_users'), isEmpty);
    });
  }, skip: url == null || url.isEmpty ? 'set DARAVEL_TEST_MYSQL' : false);
}
