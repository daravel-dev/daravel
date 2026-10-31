import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Member extends Model {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
    fillable: const ['name'],
    timestamps: false,
    relations: {
      'tries': () =>
          HasMany<Attempt>(() => Attempt.definition, foreignKey: 'member_id'),
      'latest': () => HasOne<Attempt>(
        () => Attempt.definition,
        foreignKey: 'member_id',
      ).latestOfMany('score'),
      'oldest': () => HasOne<Attempt>(
        () => Attempt.definition,
        foreignKey: 'member_id',
      ).oldestOfMany(),
      'tags': () => BelongsToMany<Tag>(
        () => Tag.definition,
        pivotTable: 'member_tag',
        foreignPivotKey: 'member_id',
        relatedPivotKey: 'tag_id',
      ),
    },
  );
  @override
  ModelDefinition<Member> get modelDefinition => definition;
}

final class Attempt extends Model {
  static final ModelDefinition<Attempt> definition = ModelDefinition<Attempt>(
    table: 'attempts',
    factory: Attempt.new,
    timestamps: false,
    softDeletes: true,
    relations: {
      'member': () => BelongsTo<Member>(
        () => Member.definition,
        foreignKey: 'member_id',
      ).withDefault((_) => Member()..setAttr('name', 'Guest')),
    },
  );
  @override
  ModelDefinition<Attempt> get modelDefinition => definition;
}

final class Tag extends Model {
  static final ModelDefinition<Tag> definition = ModelDefinition<Tag>(
    table: 'tags',
    factory: Tag.new,
    timestamps: false,
    namedGlobalScopes: {'active': (query) => query.where('active', 1)},
  );
  @override
  ModelDefinition<Tag> get modelDefinition => definition;
}

void main() {
  late Directory base;
  late Application app;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_orm_daily');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    await app.run(() async {
      for (final sql in const [
        'CREATE TABLE members (id INTEGER PRIMARY KEY, name TEXT)',
        'CREATE TABLE attempts (id INTEGER PRIMARY KEY, member_id INTEGER, '
            'score INTEGER, deleted_at TEXT)',
        'CREATE TABLE tags (id INTEGER PRIMARY KEY, active INTEGER)',
        'CREATE TABLE member_tag (member_id INTEGER, tag_id INTEGER, '
            'note TEXT)',
      ]) {
        await DB.statement(sql);
      }
      await DB.table('members').insert([
        {'id': 1, 'name': 'Ana'},
        {'id': 2, 'name': 'Budi'},
        {'id': 3, 'name': 'Citra'},
      ]);
      await DB.table('attempts').insert([
        {'id': 1, 'member_id': 1, 'score': 10, 'deleted_at': null},
        {'id': 2, 'member_id': 1, 'score': 30, 'deleted_at': null},
        {'id': 3, 'member_id': 1, 'score': 30, 'deleted_at': null},
        {'id': 4, 'member_id': 1, 'score': 99, 'deleted_at': '2026'},
        {'id': 5, 'member_id': 2, 'score': 5, 'deleted_at': null},
        {'id': 6, 'member_id': null, 'score': 1, 'deleted_at': null},
      ]);
      await DB.table('tags').insert([
        {'id': 1, 'active': 1},
        {'id': 2, 'active': 1},
        {'id': 3, 'active': 0},
      ]);
    });
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test(
    'whereNone',
    () => app.run(() async {
      final rows = await DB
          .table('members')
          .whereNone(['name'], 'like', 'A%')
          .orderBy('id')
          .get();
      expect([for (final r in rows) r['id']], [2, 3]);
    }),
  );

  test(
    'updateQuietly and deleteQuietly fire nothing',
    () => app.run(() async {
      final member = (await Member.definition.query().find(1))!;
      expect(await member.updateQuietly({'name': 'Quiet'}), isTrue);
      expect(
        (await DB.table('members').where('id', 1).first())!['name'],
        'Quiet',
      );
      expect(await member.deleteQuietly(), isTrue);
      expect(await DB.table('members').where('id', 1).first(), isNull);
    }),
  );

  group('named global scopes', () {
    test(
      'apply by default, and one comes off',
      () => app.run(() async {
        expect(await Tag.definition.query().count(), 2);
        expect(
          await Tag.definition.query().withoutGlobalScope('active').count(),
          3,
        );
        expect(
          await Tag.definition.query().withoutGlobalScopes(['active']).count(),
          3,
        );
        expect(await Tag.definition.query().withoutGlobalScopes().count(), 3);
      }),
    );
  });

  group('withDefault', () {
    test(
      'stands in for a missing owner',
      () => app.run(() async {
        final attempt = (await Attempt.definition
            .query()
            .with_('member')
            .find(6))!;
        final member = attempt.relations['member']! as Member;
        expect(member.getAttr<String>('name'), 'Guest');
        expect(member.exists, isFalse);
      }),
    );

    test(
      'a real owner wins',
      () => app.run(() async {
        final attempt = (await Attempt.definition
            .query()
            .with_('member')
            .find(5))!;
        final member = attempt.relations['member']! as Member;
        expect(member.getAttr<String>('name'), 'Budi');
      }),
    );
  });

  group('ofMany', () {
    test(
      'eager loading picks the row, per parent',
      () => app.run(() async {
        final members = await Member.definition
            .query()
            .with_('latest')
            .orderBy('id')
            .get();
        int? id(Member m) =>
            (m.relations['latest'] as Attempt?)?.getAttr<int>('id');
        // Soft deleted 99 does not count; of the two 30s, the newer id.
        expect(id(members[0]), 3);
        expect(id(members[1]), 5);
        expect(id(members[2]), isNull);
      }),
    );

    test(
      'one query, whatever the number of rows',
      () => app.run(() async {
        final members = await Member.definition.query().get();
        final sql = <String>[];
        DB.listen((event) => sql.add(event.sql));
        await members.load('latest');
        expect(sql, hasLength(1));
        expect(sql.single.toUpperCase(), contains('MAX('));
      }),
    );

    test(
      'oldestOfMany and the lazy query',
      () => app.run(() async {
        final member = (await Member.definition.query().find(1))!;
        await member.load('oldest');
        expect((member.relations['oldest']! as Attempt).getAttr<int>('id'), 1);
        final lazy = await member.relatedQuery<Attempt>('latest').first();
        expect(lazy!.getAttr<int>('id'), 3);
      }),
    );

    test('an unknown aggregate is refused', () {
      expect(
        () => HasOne<Attempt>(
          () => Attempt.definition,
          foreignKey: 'member_id',
        ).ofMany('score', 'sum'),
        throwsArgumentError,
      );
    });
  });

  group('pivots', () {
    BelongsToMany<Tag> tags() =>
        Member.definition.relation('tags')! as BelongsToMany<Tag>;

    Future<List<Object?>> attached() async {
      final rows = await DB
          .table('member_tag')
          .where('member_id', 1)
          .orderBy('tag_id')
          .get();
      return [for (final r in rows) r['tag_id']];
    }

    test(
      'syncWithoutDetaching keeps the others',
      () => app.run(() async {
        final member = (await Member.definition.query().find(1))!;
        final db = App.make<DatabaseManager>();
        await tags().attach(member, db, [1], const {});
        final result = await tags().syncWithoutDetaching(member, db, [1, 2]);
        expect(result['attached'], [2]);
        expect(result['detached'], isEmpty);
        expect(await attached(), [1, 2]);
      }),
    );

    test(
      'toggle flips each id',
      () => app.run(() async {
        final member = (await Member.definition.query().find(1))!;
        final db = App.make<DatabaseManager>();
        await tags().attach(member, db, [1], const {});
        final result = await tags().toggle(member, db, [1, 2]);
        expect(result, {
          'attached': [2],
          'detached': [1],
        });
        expect(await attached(), [2]);
      }),
    );

    test(
      'updateExistingPivot touches one row',
      () => app.run(() async {
        final member = (await Member.definition.query().find(1))!;
        final db = App.make<DatabaseManager>();
        await tags().attach(member, db, [1, 2], const {});
        final count = await tags().updateExistingPivot(member, db, 2, {
          'note': 'x',
        });
        expect(count, 1);
        final rows = await DB.table('member_tag').whereNotNull('note').get();
        expect(rows.single['tag_id'], 2);
      }),
    );
  });
}
