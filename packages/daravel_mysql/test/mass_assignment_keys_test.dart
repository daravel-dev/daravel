import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

final class Guarded extends Model {
  static final ModelDefinition<Guarded> definition = ModelDefinition<Guarded>(
    table: 'ma_users',
    factory: Guarded.new,
    timestamps: false,
    guarded: const ['role', 'meta'],
    casts: {'meta': const JsonCast()},
    relations: {
      'posts': () => HasMany<GuardedPost>(
        () => GuardedPost.definition,
        foreignKey: 'user_id',
      ),
    },
  );
  @override
  ModelDefinition<Guarded> get modelDefinition => definition;
}

final class GuardedPost extends Model {
  static final ModelDefinition<GuardedPost> definition =
      ModelDefinition<GuardedPost>(
        table: 'ma_posts',
        factory: GuardedPost.new,
        timestamps: false,
        guarded: const ['role'],
      );
  @override
  ModelDefinition<GuardedPost> get modelDefinition => definition;
}

final class Fillable extends Model {
  static final ModelDefinition<Fillable> definition = ModelDefinition<Fillable>(
    table: 'ma_users',
    factory: Fillable.new,
    timestamps: false,
    fillable: const ['name', 'meta'],
    casts: {'meta': const JsonCast()},
  );
  @override
  ModelDefinition<Fillable> get modelDefinition => definition;
}

/// The keys that wrote a guarded column before: the grammar trims keys,
/// SQLite and MySQL match column names in any case, MySQL accepts a
/// table-qualified column, and `->` writes into a JSON column.
const List<String> bypassKeys = [
  'role ',
  ' role',
  'ROLE',
  'ma_users.role',
  'meta->role',
];

/// The MySQL run of `daravel`'s `test/database/mass_assignment_keys_test.dart`
/// (the `isFillable` cases live there): MySQL matches column names in any
/// case and accepts a table-qualified column, so `ROLE` and
/// `ma_users.role` wrote the guarded column here too. Runs only with
/// `DARAVEL_TEST_MYSQL`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  Application build() {
    final uri = Uri.parse(url!);
    final user = uri.userInfo.split(':');
    return Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'mysql',
          'DB_HOST': uri.host,
          'DB_PORT': '${uri.port}',
          'DB_DATABASE': uri.path.replaceFirst('/', ''),
          'DB_USERNAME': user.first,
          'DB_PASSWORD': user.length > 1 ? user[1] : '',
        })
        .withLogLevel(LogLevel.critical)
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .create();
  }

  final runs = <String, Application Function()>{
    if (url != null && url.isNotEmpty) 'MySQL': build,
  };
  if (runs.isEmpty) {
    test('MySQL (skipped: DARAVEL_TEST_MYSQL not set)', () {}, skip: true);
  }

  for (final MapEntry(key: name, value: create) in runs.entries) {
    group(name, () {
      late Application app;

      setUp(() async {
        Model.preventSilentlyDiscardingAttributes = false;
        app = create();
        await app.boot();
        await app.run(() async {
          final schema = await Schema.builder();
          await schema.dropIfExists('ma_posts');
          await schema.dropIfExists('ma_users');
          await schema.create('ma_users', (t) {
            t.id();
            t.string('name').nullable();
            t.string('role').nullable();
            t.json('meta').nullable();
          });
          await schema.create('ma_posts', (t) {
            t.id();
            t.integer('user_id').nullable();
            t.string('title').nullable();
            t.string('role').nullable();
          });
        });
      });

      tearDown(() async {
        Model.preventSilentlyDiscardingAttributes = false;
        await app.run(() async {
          final schema = await Schema.builder();
          await schema.dropIfExists('ma_posts');
          await schema.dropIfExists('ma_users');
        });
        await app.shutdown();
      });

      /// A user whose guarded columns hold `user`.
      Future<Guarded> seeded() async {
        final user = Guarded.definition.newInstance()
          ..forceFill({
            'name': 'Ana',
            'role': 'user',
            'meta': {'role': 'user'},
          });
        await user.save();
        return user;
      }

      Future<(Object?, Object?)> guardedOf(Object? id) async {
        final row = (await DB.table('ma_users').where('id', id).first())!;
        final meta = row['meta'];
        return (
          row['role'],
          meta == null ? null : Guarded.definition.casts['meta']!.get(meta),
        );
      }

      void expectUntouched((Object?, Object?) values, String key) {
        expect(values.$1, anyOf(isNull, 'user'), reason: 'role via $key');
        expect(
          values.$2,
          anyOf(isNull, {'role': 'user'}),
          reason: 'meta via $key',
        );
      }

      for (final key in bypassKeys) {
        test('fill + save with ${key.trim()} (${key.length} chars) keeps the '
            'guarded column', () async {
          await app.run(() async {
            final user = await seeded();
            user.fill({key: 'admin', 'name': 'Bo'});
            await user.save();
            expectUntouched(await guardedOf(user.key), key);
            expect(
              (await DB
                  .table('ma_users')
                  .where('id', user.key)
                  .first())!['name'],
              'Bo',
            );
          });
        });

        test('create with ${key.trim()} (${key.length} chars) leaves the '
            'guarded column empty', () async {
          await app.run(() async {
            final user = await Guarded.definition.query().create({
              key: 'admin',
              'name': 'Bo',
            });
            expectUntouched(await guardedOf(user.key), key);
          });
        });
      }

      test('every path that mass assigns: update, firstOrCreate, '
          'updateOrCreate, newInstance, a relation create', () async {
        await app.run(() async {
          for (final key in bypassKeys) {
            final user = await seeded();
            await user.update({key: 'admin'});
            expectUntouched(await guardedOf(user.key), 'update $key');

            final first = await Guarded.definition.query().firstOrCreate(
              {'name': 'first $key'},
              {key: 'admin'},
            );
            expectUntouched(await guardedOf(first.key), 'firstOrCreate $key');

            final upserted = await Guarded.definition.query().updateOrCreate(
              {'name': 'Ana'},
              {key: 'admin'},
            );
            expectUntouched(
              await guardedOf(upserted.key),
              'updateOrCreate $key',
            );
            final created = await Guarded.definition.query().updateOrCreate(
              {'name': 'new $key'},
              {key: 'admin'},
            );
            expectUntouched(
              await guardedOf(created.key),
              'updateOrCreate $key',
            );

            final fresh = Guarded.definition.newInstance({
              key: 'admin',
              'name': 'fresh',
            });
            await fresh.save();
            expectUntouched(await guardedOf(fresh.key), 'newInstance $key');

            final postKey = key.replaceAll('ma_users', 'ma_posts');
            final relation = Guarded.definition.requireRelation(
              'posts',
            ) as HasMany<GuardedPost>;
            final post = await relation.create(
              user,
              App.make<DatabaseManager>(),
              {postKey: 'admin', 'title': 't'},
            );
            final row = (await DB
                .table('ma_posts')
                .where('id', post.key)
                .first())!;
            expect(row['role'], isNull, reason: 'relation create $postKey');
          }
        });
      });

      test('with preventSilentlyDiscardingAttributes the key is refused '
          'as a guarded one', () async {
        Model.preventSilentlyDiscardingAttributes = true;
        await app.run(() async {
          final user = await seeded();
          for (final key in bypassKeys) {
            expect(
              () => user.fill({key: 'admin'}),
              throwsA(isA<MassAssignmentException>()),
              reason: key,
            );
          }
        });
      });

      test(
        'random spellings of the guarded columns never change them',
        () async {
          final random = Random(20261113);
          final pieces = [
            ' ',
            String.fromCharCode(9), // tab
            '.',
            '->',
            String.fromCharCode(0),
            String.fromCharCode(0x00a0), // no-break space
            '_',
            String.fromCharCode(0x043e), // Cyrillic o
          ];
          String spell() {
            final base = random.nextBool() ? 'role' : 'meta';
            final cased = String.fromCharCodes([
              for (final c in base.codeUnits)
                random.nextBool() && c >= 97 ? c - 32 : c,
            ]);
            final before = random.nextInt(3) == 0
                ? pieces[random.nextInt(pieces.length)]
                : '';
            final after = random.nextInt(2) == 0
                ? pieces[random.nextInt(pieces.length)] +
                      (random.nextBool() ? 'role' : '')
                : '';
            final table = random.nextInt(4) == 0 ? 'ma_users.' : '';
            return '$table$before$cased$after';
          }

          await app.run(() async {
            final user = await seeded();
            for (var i = 0; i < 300; i++) {
              final key = spell();
              try {
                user.fill({key: 'admin'});
                await user.save();
              } on QueryException {
                // A key that is no column at all: refused by the database.
                await user.refresh();
              }
              expectUntouched(await guardedOf(user.key), key);
            }
          });
        },
      );
    });
  }
}
