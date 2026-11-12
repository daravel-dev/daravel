@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/test_databases.dart';

/// `Schema.getForeignKeys` on PostgreSQL (`DARAVEL_TEST_PG`): Laravel 13's
/// query and shape, the one-letter actions named as its
/// `PostgresProcessor` names them.
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG'];

  test('names, columns in order, actions', () async {
    final db = postgresFromUrl(url!);
    addTearDown(db.closeAll);
    final schema = await freshSchema(db, const [
      'fk_users',
      'fk_assessments',
      'fk_pairs',
      'fk_sessions',
      'fk_grades',
    ]);
    for (final sql in [
      'create table fk_users (id bigserial primary key)',
      'create table fk_assessments (id bigserial primary key)',
      'create table fk_pairs (a bigint, b bigint, primary key (a, b))',
      'create table fk_sessions (id bigserial primary key, '
          'assessment_id bigint not null, user_id bigint, parent_id bigint, '
          'constraint fk_sessions_assessment foreign key (assessment_id) '
          'references fk_assessments (id) on delete cascade, '
          'constraint fk_sessions_user foreign key (user_id) '
          'references fk_users (id) on delete set null on update cascade, '
          'constraint fk_sessions_parent foreign key (parent_id) '
          'references fk_sessions (id))',
      'create table fk_grades (id bigserial primary key, s bigint, t bigint, '
          'constraint fk_grades_pair foreign key (t, s) '
          'references fk_pairs (b, a) on delete restrict on update set default)',
    ]) {
      await db.statement(sql);
    }
    final sessions = {
      for (final key in await schema.getForeignKeys('fk_sessions'))
        key.name: key,
    };
    expect(sessions.keys.toSet(), {
      'fk_sessions_assessment',
      'fk_sessions_user',
      'fk_sessions_parent',
    });
    final user = sessions['fk_sessions_user']!;
    expect(user.columns, ['user_id']);
    expect(user.foreignTable, 'fk_users');
    expect(user.foreignColumns, ['id']);
    expect(user.foreignSchema, 'public');
    expect(user.onUpdate, 'cascade');
    expect(user.onDelete, 'set null');
    expect(sessions['fk_sessions_assessment']!.onDelete, 'cascade');
    expect(sessions['fk_sessions_parent']!.onDelete, 'no action');
    expect(sessions['fk_sessions_parent']!.foreignTable, 'fk_sessions');
    final pair = (await schema.getForeignKeys('fk_grades')).single;
    expect(pair.columns, ['t', 's'], reason: 'in constraint order');
    expect(pair.foreignColumns, ['b', 'a']);
    expect(pair.onDelete, 'restrict');
    expect(pair.onUpdate, 'set default');
    expect(await schema.getForeignKeys('fk_users'), isEmpty);
    expect(await schema.getForeignKeys('no_such_table'), isEmpty);
  }, skip: url == null || url.isEmpty ? 'set DARAVEL_TEST_PG' : false);
}
