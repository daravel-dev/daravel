import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Refused queries as Laravel's `QueryException` and
/// `UniqueConstraintViolationException`, and `createOrFirst` /
/// `firstOrCreate` that survive a concurrent create.
final class Member extends Model {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
    guarded: [],
    timestamps: false,
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;
}

void main() {
  late Application app;

  Future<Application> boot([Map<String, String> env = const {}]) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'LOG_LEVEL': 'error',
          ...env,
        })
        .withRouting(
          api: (r) => r.post('/members', (_) async {
            await DB.table('members').insert({
              'email': 'ana@x.io',
              'name': 'Ana',
            });
            return 'created';
          }),
        )
        .create();
    await app.boot();
    await app.run(
      () => Schema.create('members', (t) {
        t.id();
        t.string('email').unique();
        t.string('name');
      }),
    );
    return app;
  }

  setUp(() async => app = await boot());
  tearDown(() => app.shutdown());

  test('a duplicate is a UniqueConstraintViolationException', () async {
    await app.run(() async {
      await DB.table('members').insert({'email': 'a@x.io', 'name': 'secret'});
      Object? error;
      try {
        await DB.table('members').insert({'email': 'a@x.io', 'name': 'B'});
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<UniqueConstraintViolationException>());
      final violation = error! as UniqueConstraintViolationException;
      expect(violation.connectionName, 'sqlite');
      expect(violation.sql, startsWith('INSERT INTO "members"'));
      expect(violation.bindings, ['a@x.io', 'B']);
      expect(violation.previous.runtimeType.toString(), contains('Sqlite'));
      expect(violation.message, contains('UNIQUE constraint failed'));
      // The values stay out of the message (and so out of logs).
      expect(violation.message, isNot(contains('a@x.io')));
      expect(violation.message, contains('(Connection: sqlite, SQL: INSERT'));

      // A primary key too.
      final id = (await DB.table('members').first())!['id'];
      await expectLater(
        DB.table('members').insert({'id': id, 'email': 'c@x.io', 'name': 'C'}),
        throwsA(isA<UniqueConstraintViolationException>()),
      );
    });
  });

  test('other refusals are a QueryException', () async {
    await app.run(() async {
      await expectLater(
        DB.table('missing').get(),
        throwsA(
          isA<QueryException>()
              .having(
                (e) => e,
                'type',
                isNot(isA<UniqueConstraintViolationException>()),
              )
              .having((e) => e.sql, 'sql', contains('"missing"')),
        ),
      );
    });
  });

  test('inside a transaction it rolls the transaction back', () async {
    await app.run(() async {
      await DB.table('members').insert({'email': 'a@x.io', 'name': 'A'});
      await expectLater(
        DB.transaction(() async {
          await DB.table('members').insert({'email': 'b@x.io', 'name': 'B'});
          await DB.table('members').insert({'email': 'a@x.io', 'name': 'A2'});
        }),
        throwsA(isA<UniqueConstraintViolationException>()),
      );
      expect(await DB.table('members').count(), 1);
    });
  });

  test('firstOrCreate racing itself creates one row', () async {
    await app.run(() async {
      final members = await Future.wait([
        for (var i = 0; i < 20; i++)
          Member.definition.query().firstOrCreate(
            {'email': 'race@x.io'},
            {'name': 'Racer $i'},
          ),
      ]);
      expect({for (final m in members) m.attributes['id']}, hasLength(1));
      expect(await DB.table('members').count(), 1);
    });
  });

  test('createOrFirst returns the row a unique index already holds', () async {
    await app.run(() async {
      final first = await Member.definition.query().createOrFirst(
        {'email': 'x@x.io'},
        {'name': 'First'},
      );
      expect(first.wasRecentlyCreated, isTrue);
      final again = await Member.definition.query().createOrFirst(
        {'email': 'x@x.io'},
        {'name': 'Second'},
      );
      expect(again.attributes['id'], first.attributes['id']);
      expect(again.attributes['name'], 'First');
      expect(again.wasRecentlyCreated, isFalse);

      // In a transaction, the refused insert is a savepoint: the rest of
      // the transaction carries on and commits.
      await DB.transaction(() async {
        await Member.definition.query().createOrFirst(
          {'email': 'x@x.io'},
          {'name': 'Third'},
        );
        await DB.table('members').insert({'email': 'y@x.io', 'name': 'Y'});
      });
      expect(await DB.table('members').count(), 2);
    });
  });

  test('updateOrCreate creates once, then updates', () async {
    await app.run(() async {
      final created = await Member.definition.query().updateOrCreate(
        {'email': 'u@x.io'},
        {'name': 'One'},
      );
      final updated = await Member.definition.query().updateOrCreate(
        {'email': 'u@x.io'},
        {'name': 'Two'},
      );
      expect(updated.attributes['id'], created.attributes['id']);
      expect((await DB.table('members').first())!['name'], 'Two');
    });
  });

  test('unhandled, it is a 500 that shows no SQL outside debug', () async {
    final production = await boot({
      'APP_ENV': 'production',
      'APP_DEBUG': 'false',
      'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    });
    addTearDown(production.shutdown);
    final first = await production.handle(
      Request.fake(method: 'POST', path: '/api/members'),
    );
    expect(first.status, 200);
    final second = await production.handle(
      Request.fake(method: 'POST', path: '/api/members'),
    );
    expect(second.status, 500);
    final body = await second.bodyText();
    // Laravel's prepareJsonResponse: JSON_PRETTY_PRINT.
    expect(body, '{\n    "message": "Server Error"\n}');
  });
}
