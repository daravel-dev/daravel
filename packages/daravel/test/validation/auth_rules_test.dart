import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Member extends Model with AuthenticatableModel {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'users',
    factory: Member.new,
    fillable: ['name', 'email', 'password'],
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;
}

final class CreateUsers extends Migration {
  const CreateUsers();

  @override
  String get name => '2026_01_01_000000_create_users';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.string('password');
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

final class _Verifier implements CurrentPasswordVerifier {
  final List<(String, String?)> calls = [];

  @override
  Future<bool> verify(String password, {String? guard}) async {
    calls.add((password, guard));
    return password == 'secret';
  }
}

final class _Checker implements AbilityChecker {
  final List<(String, List<Object?>)> calls = [];

  @override
  Future<bool> allows(String ability, List<Object?> arguments) async {
    calls.add((ability, arguments));
    return !arguments.contains('denied');
  }
}

/// `current_password` and `Rule::can` (W9.4a): asked through interfaces
/// the validation module owns, answered by the auth module that the
/// Application binds.
void main() {
  group('through the interfaces', () {
    late _Verifier verifier;
    late _Checker checker;
    late Container container;

    setUp(() {
      verifier = _Verifier();
      checker = _Checker();
      container = Container()
        ..instance<CurrentPasswordVerifier>(verifier)
        ..instance<AbilityChecker>(checker);
    });

    Future<Map<String, List<String>>> errorsOf(
      Map<String, Object?> data,
      Map<String, Object> rules,
    ) => Validator(data, rules, container: container).run();

    test('current_password asks the verifier, with the guard', () async {
      expect(
        await errorsOf(
          {'password': 'secret'},
          {'password': 'current_password'},
        ),
        isEmpty,
      );
      expect(
        await errorsOf(
          {'password': 'nope'},
          {'password': 'current_password:api'},
        ),
        {
          'password': ['The password is incorrect.'],
        },
      );
      expect(verifier.calls, [('secret', null), ('nope', 'api')]);
    });

    test('current_password: not a string fails; empty is skipped', () async {
      expect(
        (await errorsOf(
          {'password': 42},
          {'password': Rules.currentPassword()},
        )).keys,
        ['password'],
      );
      expect(
        await errorsOf({'password': ''}, {'password': Rules.currentPassword()}),
        isEmpty,
      );
      expect(verifier.calls, isEmpty);
    });

    test('can passes the arguments, then the value', () async {
      final post = Object();
      expect(
        await errorsOf(
          {'tag': 'news'},
          {
            'tag': Rules.can('attach-tag', [post]),
          },
        ),
        isEmpty,
      );
      expect(checker.calls.single.$1, 'attach-tag');
      expect(checker.calls.single.$2, [post, 'news']);
      expect(
        await errorsOf({'tag': 'denied'}, {'tag': Rules.can('attach-tag')}),
        {
          'tag': ['The tag field contains an unauthorized value.'],
        },
      );
    });

    test('can drops what PHP array_filter drops, as Laravel', () async {
      await errorsOf(
        {'n': 0},
        {
          'n': Rules.can('x', [
            null,
            false,
            0,
            0.0,
            '',
            '0',
            <Object?>[],
            'keep',
          ]),
        },
      );
      // The value 0 is dropped too.
      expect(checker.calls.single.$2, ['keep']);
    });
  });

  group('without a binding', () {
    test('current_password says what to install, never passes', () {
      expect(
        Validator({'p': 'secret'}, {'p': 'current_password'}).run(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('CurrentPasswordVerifier'),
          ),
        ),
      );
    });

    test('can says what to install, never passes', () {
      expect(
        Validator(
          {'t': 'x'},
          {'t': Rules.can('a')},
          container: Container(),
        ).run(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('AbilityChecker'),
          ),
        ),
      );
    });
  });

  group('in an Application', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'APP_KEY': Encrypter.generateKey(),
            'HASH_DRIVER': 'bcrypt',
            'BCRYPT_ROUNDS': '4',
          })
          .withMigrations(const [CreateUsers()])
          .withAuth((auth) {
            final members = ModelUserProvider<Member>(Member.definition);
            auth
              ..token<Member>('token', members)
              ..token<Member>('admin', members);
          })
          .withPolicies(
            (gate) => gate.define(
              'attach-tag',
              (user, args) => user != null && args.last != 'denied',
            ),
          )
          .create();
      await app.boot();
      await app.run(() => App.make<Migrator>().run());
    });

    tearDown(() => app.shutdown());

    Future<Map<String, List<String>>> errorsOf(
      Map<String, Object?> data,
      Map<String, Object> rules,
    ) => Validator(data, rules, container: Container.current).run();

    test('current_password checks the signed-in user, a guest fails', () async {
      await app.run(() async {
        final ana = await Member.definition.query().create({
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': await Hash.make('secret'),
        });
        Auth.setUser(ana);
        expect(
          await errorsOf({'p': 'secret'}, {'p': 'current_password'}),
          isEmpty,
        );
        expect(
          (await errorsOf({'p': 'nope'}, {'p': 'current_password'})).keys,
          ['p'],
        );
        Auth.forgetUser();
        expect(
          (await errorsOf({'p': 'secret'}, {'p': 'current_password'})).keys,
          ['p'],
        );
      });
    });

    test(
      'current_password:guard checks that guard, not the active one',
      () async {
        await app.run(() async {
          Future<Member> member(String name, String password) async =>
              await Member.definition.query().create({
                'name': name,
                'email': '$name@example.com',
                'password': await Hash.make(password),
              });
          final ana = await member('ana', 'ana-secret');
          final bo = await member('bo', 'bo-secret');
          Auth.setUser(ana, guard: 'token');
          Auth.setUser(bo, guard: 'admin');
          Future<bool> passes(String password, Object rule) async =>
              (await errorsOf({'p': password}, {'p': rule})).isEmpty;
          expect(await passes('ana-secret', 'current_password:token'), isTrue);
          expect(await passes('bo-secret', 'current_password:token'), isFalse);
          expect(await passes('bo-secret', 'current_password:admin'), isTrue);
          expect(
            await passes('ana-secret', Rules.currentPassword(guard: 'admin')),
            isFalse,
          );
          // The default guard is token: ana's.
          expect(await passes('ana-secret', 'current_password'), isTrue);
          Auth.forgetUser(guard: 'admin');
          expect(await passes('bo-secret', 'current_password:admin'), isFalse);
          expect(await passes('ana-secret', 'current_password:token'), isTrue);
        });
      },
    );

    test('can asks the gate for the current user', () async {
      await app.run(() async {
        final bo = await Member.definition.query().create({
          'name': 'Bo',
          'email': 'bo@example.com',
          'password': await Hash.make('x'),
        });
        final rules = <String, Object>{'tag': Rules.can('attach-tag')};
        expect((await errorsOf({'tag': 'news'}, rules)).keys, ['tag']);
        Auth.setUser(bo);
        expect(await errorsOf({'tag': 'news'}, rules), isEmpty);
        expect((await errorsOf({'tag': 'denied'}, rules)).keys, ['tag']);
      });
    });
  });
}
