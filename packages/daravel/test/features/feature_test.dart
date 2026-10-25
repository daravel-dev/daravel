import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

final class Member extends Model {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
  );
  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;

  static Member withId(int id) => Member()..setAttr('id', id);
}

void main() {
  group('array store', () {
    late FeatureManager features;
    late int calls;
    Object? user;

    setUp(() {
      calls = 0;
      user = null;
      features =
          FeatureManager(ArrayFeatureStore(), defaultScope: () async => user)
            ..define('beta', (scope) {
              calls++;
              return scope is Member && (scope.key! as int).isEven;
            })
            ..define('checkout', (scope) => scope == null ? 'classic' : 'v2');
    });

    test('resolves once per scope and stores the value', () async {
      user = Member.withId(2);
      expect(await features.active('beta'), isTrue);
      expect(await features.active('beta'), isTrue);
      expect(calls, 1);
      expect(await features.forScope(Member.withId(3)).active('beta'), isFalse);
      expect(calls, 2);
      expect(
        await features.forScope(Member.withId(3)).inactive('beta'),
        isTrue,
      );
      expect(calls, 2);
    });

    test(
      'rich values are active unless false; unknown features are off',
      () async {
        expect(await features.value('checkout'), 'classic');
        expect(await features.active('checkout'), isTrue);
        user = Member.withId(1);
        expect(await features.value('checkout'), 'v2');
        expect(await features.active('nope'), isFalse);
        expect(await features.store.get('nope', '__laravel_null'), (
          found: false,
          value: null,
        ), reason: 'unknown features are not stored');
        expect(await features.allAreActive(['checkout', 'nope']), isFalse);
        expect(await features.someAreActive(['checkout', 'nope']), isTrue);
      },
    );

    test('activate, deactivate, forget, for everyone and purge', () async {
      final member = Member.withId(5);
      final scoped = features.forScope(member);
      expect(await scoped.active('beta'), isFalse);
      await scoped.activate('beta');
      expect(await scoped.active('beta'), isTrue);
      await scoped.deactivate('beta');
      expect(await scoped.active('beta'), isFalse);
      await scoped.activate('beta', 'canary');
      expect(await scoped.value('beta'), 'canary');
      await scoped.forget('beta');
      expect(await scoped.value('beta'), isFalse, reason: 'resolved again');

      await features.forScope(Member.withId(2)).active('beta');
      await features.activateForEveryone('beta');
      expect(await scoped.active('beta'), isTrue);
      expect(await features.forScope(Member.withId(2)).active('beta'), isTrue);
      await features.deactivateForEveryone('beta');
      expect(await scoped.active('beta'), isFalse);

      await features.purge(['beta']);
      calls = 0;
      await scoped.active('beta');
      expect(calls, 1, reason: 'purged values resolve again');
    });

    test('scopes serialize as Pennant serializes them', () {
      expect(features.serializeScope(null), '__laravel_null');
      expect(features.serializeScope('team-7'), 'team-7');
      expect(features.serializeScope(7), '7');
      expect(features.serializeScope(1.5), '1.5');
      expect(features.serializeScope(Member.withId(9)), r'App\Models\Member|9');
      expect(() => features.serializeScope(Object()), throwsStateError);
    });
  });

  forEachDatabase(featureDatabaseTests);

  group('in an application', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (router) {
              router.get('/beta', (_) => {'ok': true}).middleware(const [
                'feature:beta',
              ]);
              router.get('/both', (_) => {'ok': true}).middleware(const [
                'feature:beta,checkout',
              ]);
            },
          )
          .create();
      await app.boot();
      app.container.make<FeatureManager>()
        ..define('beta', (_) => false)
        ..define('checkout', (_) => true);
    });
    tearDown(() => app.shutdown());

    test(
      'the feature middleware answers 400 unless every feature is on',
      () async {
        final client = TestClient(app);
        final off = await client.get('/api/beta');
        off.assertStatus(400);
        expect(jsonDecode(off.body), {'message': ''});
        (await client.get('/api/both')).assertStatus(400);

        await app.run(() => Feature.activateForEveryone('beta'));
        await app.run(() => Feature.forScope(null).activate('beta'));
        (await client.get('/api/beta')).assertOk();
        (await client.get('/api/both')).assertOk();
      },
    );

    test('testing uses the array store; the facade works in a scope', () async {
      expect(
        app.container.make<FeatureManager>().store,
        isA<ArrayFeatureStore>(),
      );
      await app.run(() async {
        expect(await Feature.active('checkout'), isTrue);
        expect(await Feature.inactive('beta'), isTrue);
      });
    });
  });
}

/// The database store, also run on MySQL and MariaDB by
/// `daravel_mysql/test/orm_matrix_test.dart`.
void featureDatabaseTests(DatabaseOpener open) {
  late DatabaseManager db;
  late FeatureManager features;

  setUp(() async {
    db = open();
    await db.statement('DROP TABLE IF EXISTS features');
    await const CreateFeaturesTable().up(SchemaBuilder(await db.executor()));
    features =
        FeatureManager(DatabaseFeatureStore(db), defaultScope: () async => null)
          ..define('beta', (scope) => scope is Member)
          ..define('checkout', (_) => 'v2');
  });
  tearDown(() async {
    await db.statement('DROP TABLE IF EXISTS features');
    await db.closeAll();
  });

  test("stores values in Pennant's features table", () async {
    expect(await features.active('beta'), isFalse);
    expect(await features.forScope(Member.withId(1)).active('beta'), isTrue);
    expect(await features.value('checkout'), 'v2');
    final rows = await db
        .table('features')
        .select(const ['name', 'scope', 'value'])
        .orderBy('id')
        .get();
    expect(rows, [
      {'name': 'beta', 'scope': '__laravel_null', 'value': 'false'},
      {'name': 'beta', 'scope': r'App\Models\Member|1', 'value': 'true'},
      {'name': 'checkout', 'scope': '__laravel_null', 'value': '"v2"'},
    ]);
  });

  test('reads values a Laravel application stored', () async {
    await db.table('features').insert({
      'name': 'beta',
      'scope': r'App\Models\Member|4',
      'value': '"from-laravel"',
      'created_at': '2026-10-25 00:00:00',
      'updated_at': '2026-10-25 00:00:00',
    });
    expect(
      await features.forScope(Member.withId(4)).value('beta'),
      'from-laravel',
    );
  });

  test('activate upserts; for everyone updates every scope', () async {
    final scoped = features.forScope(Member.withId(2));
    await scoped.activate('beta', 'v3');
    await scoped.activate('beta', 'v4');
    expect(await db.table('features').count(), 1);
    expect(await scoped.value('beta'), 'v4');
    await features.active('beta');
    await features.deactivateForEveryone('beta');
    expect(
      ((await db.table('features').pluck('value')) as List<Object?>).toSet(),
      {'false'},
    );
    await features.purge();
    expect(await db.table('features').count(), 0);
  });
}
