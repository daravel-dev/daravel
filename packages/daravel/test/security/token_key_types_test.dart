@Tags(['security'])
library;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

final class Member extends Model with AuthenticatableModel {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;
}

Member member(Object id) => Member()..setAttr('id', id);

/// `TokenGuard.keyType`: Sanctum tokens are `<id>|<secret>`, and the id is
/// the tokens table's key, an integer by default or a UUID/ULID for a
/// `PersonalAccessToken` model with `HasUuids`/`HasUlids`. A token whose id
/// cannot be that key is refused before the query: on PostgreSQL a text id
/// compared with a `bigint` column is an error (a 500), not a miss.
void main() {
  forEachDatabase((open) {
    late DatabaseManager db;

    Future<void> tokensTable(String key) async {
      final schema = await freshSchema(db, const ['personal_access_tokens']);
      await schema.create('personal_access_tokens', (table) {
        switch (key) {
          case 'uuid':
            table.uuid('id').primary();
            table.uuidMorphs('tokenable');
          case 'ulid':
            table.ulid('id').primary();
            table.morphs('tokenable');
          default:
            table.id();
            table.morphs('tokenable');
        }
        table.text('name');
        table.string('token', length: 64).unique();
        table.text('abilities').nullable();
        table.timestamp('last_used_at').nullable();
        table.timestamp('expires_at').nullable();
        table.timestamps();
      });
    }

    TokenGuard<Member> guard(KeyType keyType) => TokenGuard<Member>(
      name: 'token',
      provider: ModelUserProvider<Member>(Member.definition),
      db: db,
      keyType: keyType,
    );

    setUp(() => db = open());
    tearDown(() async {
      await (await freshSchema(db, const [
        'personal_access_tokens',
      ])).dropIfExists('personal_access_tokens');
      await db.closeAll();
    });

    /// Ids no table key matches, nor any SQL: each must be a miss.
    const hostile = <String>[
      'abc',
      '1 OR 1=1',
      "1'; DROP TABLE personal_access_tokens; --",
      '',
      ' 1',
      '+1',
      '-1',
      '99999999999999999999',
      '0x1',
    ];

    test('autoInt (Sanctum default): integer ids only', () async {
      await tokensTable('int');
      final tokens = guard(KeyType.autoInt);
      final issued = await tokens.issue(member(7), 'mobile');
      expect(issued.accessToken.id, isA<int>());
      final secret = issued.plainTextToken.split('|').last;
      expect(
        (await tokens.findToken(issued.plainTextToken))?.id,
        issued.accessToken.id,
      );
      for (final id in [...hostile, KeyGenerator.uuid(), KeyGenerator.ulid()]) {
        expect(await tokens.findToken('$id|$secret'), isNull, reason: id);
      }
    });

    test('uuid (HasUuids): the token id is a UUID, with UUID users', () async {
      await tokensTable('uuid');
      final tokens = guard(KeyType.uuid);
      final userId = KeyGenerator.uuid();
      final issued = await tokens.issue(member(userId), 'mobile');
      final id = issued.accessToken.id;
      expect(id, isA<String>());
      expect(issued.plainTextToken, startsWith('$id|'));
      final found = await tokens.findToken(issued.plainTextToken);
      expect(found?.id, id);
      expect(found?.tokenableId, userId);

      final secret = issued.plainTextToken.split('|').last;
      expect(await tokens.findToken('$id|wrong'), isNull);
      expect(await tokens.findToken('${KeyGenerator.uuid()}|$secret'), isNull);
      for (final bad in [
        ...hostile,
        '1',
        KeyGenerator.ulid(),
        '$id ',
        id.toString().replaceAll('-', ''),
      ]) {
        expect(await tokens.findToken('$bad|$secret'), isNull, reason: bad);
      }
    });

    test('ulid (HasUlids): the token id is a ULID', () async {
      await tokensTable('ulid');
      final tokens = guard(KeyType.ulid);
      final issued = await tokens.issue(member(7), 'mobile');
      final id = issued.accessToken.id;
      expect(id, isA<String>());
      expect(id.toString(), hasLength(26));
      expect((await tokens.findToken(issued.plainTextToken))?.id, id);

      final secret = issued.plainTextToken.split('|').last;
      for (final bad in [...hostile, '1', KeyGenerator.uuid()]) {
        expect(await tokens.findToken('$bad|$secret'), isNull, reason: bad);
      }
    });

    test('a token from another table type is a miss, not an error', () async {
      await tokensTable('int');
      final ints = guard(KeyType.autoInt);
      final issued = await ints.issue(member(7), 'mobile');
      // The same table read by a guard that expects UUIDs: no match, and
      // no integer id is ever bound as text.
      expect(
        await guard(KeyType.uuid).findToken(issued.plainTextToken),
        isNull,
      );
    });
  });

  test('a key the guard cannot make or check is refused at once', () {
    for (final keyType in [KeyType.string, KeyType.manualInt]) {
      expect(
        () => TokenGuard<Member>(
          name: 'token',
          provider: ModelUserProvider<Member>(Member.definition),
          keyType: keyType,
        ),
        throwsArgumentError,
      );
    }
  });
}
