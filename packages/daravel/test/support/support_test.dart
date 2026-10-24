import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('Str (Laravel semantics)', () {
    test('case conversion', () {
      expect(Str.snake('fooBar'), 'foo_bar');
      expect(Str.snake('FooBar'), 'foo_bar');
      expect(Str.snake('Foo Bar'), 'foo_bar');
      expect(Str.snake('already_snake'), 'already_snake');
      expect(Str.kebab('emailVerifiedAt'), 'email-verified-at');
      expect(Str.studly('user_profile'), 'UserProfile');
      expect(Str.studly('user-profile photo'), 'UserProfilePhoto');
      expect(Str.camel('user_profile'), 'userProfile');
      expect(Str.title('hello WORLD'), 'Hello World');
      expect(Str.headline('emailNotificationSent'), 'Email Notification Sent');
      expect(
        Str.headline('email_notification_sent'),
        'Email Notification Sent',
      );
      expect(Str.ucfirst('daravel'), 'Daravel');
      expect(Str.lcfirst('Daravel'), 'daravel');
    });

    test('slug', () {
      expect(Str.slug('Hello World!'), 'hello-world');
      expect(Str.slug('  Laravel & Dart -- 2026 '), 'laravel-dart-2026');
      expect(Str.slug('hello_world'), 'hello-world');
      expect(Str.slug('Crème Brûlée'), 'creme-brulee');
      expect(Str.slug('me@example'), 'me-at-example');
      expect(Str.slug('Hello World', separator: '_'), 'hello_world');
    });

    test('slicing', () {
      expect(Str.after('This is my name', 'This is'), ' my name');
      expect(Str.afterLast('App\\Http\\Controllers', '\\'), 'Controllers');
      expect(Str.before('This is my name', 'my name'), 'This is ');
      expect(Str.beforeLast('This is my name', 'is'), 'This ');
      expect(Str.between('This is my name', 'This', 'name'), ' is my ');
      expect(Str.limit('The quick brown fox jumps', 9), 'The quick...');
      expect(Str.limit('short', 10), 'short');
      expect(
        Str.words('Perfectly balanced, as all things', 3, ' >>>'),
        'Perfectly balanced, as >>>',
      );
      expect(Str.mask('taylor@example.com', '*', 3), 'tay***************');
      expect(Str.mask('taylor@example.com', '*', -15, 3), 'tay***@example.com');
      expect(Str.squish('  laravel    framework  '), 'laravel framework');
      expect(Str.start('this/string', '/'), '/this/string');
      expect(Str.finish('this/string', '/'), 'this/string/');
      expect(Str.replaceFirst('the', 'a', 'the quick the'), 'a quick the');
      expect(Str.replaceLast('the', 'a', 'the quick the'), 'the quick a');
      expect(Str.padBoth('James', 10, '_'), '__James___');
      expect(Str.padLeft('James', 10, '-='), '-=-=-James');
      expect(Str.padRight('James', 10, '-'), 'James-----');
      expect(Str.wordCount('Hello, world!'), 2);
    });

    test('predicates', () {
      expect(Str.contains('This is my name', 'my'), isTrue);
      expect(Str.contains('This is my name', ['xyz', 'name']), isTrue);
      expect(Str.contains('This is my name', 'MY', ignoreCase: true), isTrue);
      expect(Str.contains('abc', ''), isFalse);
      expect(Str.containsAll('This is my name', ['my', 'name']), isTrue);
      expect(Str.startsWith('This is my name', ['xx', 'This']), isTrue);
      expect(Str.endsWith('This is my name', 'name'), isTrue);
      expect(Str.isUuid('a0a2a2d2-0b87-4a18-83f2-2529882be2de'), isTrue);
      expect(Str.isUuid('nope'), isFalse);
      expect(Str.isUlid(Str.ulid()), isTrue);
      expect(Str.isJson('{"a":1}'), isTrue);
      expect(Str.isJson('{a:1}'), isFalse);
    });

    test('generators', () {
      expect(Str.random(), hasLength(16));
      expect(Str.random(40), matches(RegExp(r'^[A-Za-z0-9]{40}$')));
      expect(Str.isUuid(Str.uuid()), isTrue);
      expect(Str.ulid(), hasLength(26));
    });

    test('plural and singular (English)', () {
      const pairs = {
        'post': 'posts',
        'category': 'categories',
        'box': 'boxes',
        'church': 'churches',
        'day': 'days',
        'person': 'people',
        'child': 'children',
        'status': 'statuses',
        'quiz': 'quizzes',
        'knife': 'knives',
        'sheep': 'sheep',
        'information': 'information',
      };
      pairs.forEach((single, many) {
        expect(Str.plural(single), many, reason: single);
        expect(Str.singular(many), single, reason: many);
      });
      expect(Str.plural('post', 1), 'post');
      expect(Str.plural('Post'), 'Posts');
      expect(Str.plural('CHILD'), 'CHILDREN');
      expect(Str.plural('blog_post'), 'blog_posts');
      expect(Str.pluralStudly('UserProfile'), 'UserProfiles');
      expect(Str.singular('addresses'), 'address');
    });
  });

  group('helpers', () {
    test('blank and filled', () {
      for (final v in [null, '', '   ', <int>[], <String, int>{}]) {
        expect(blank(v), isTrue, reason: '$v');
      }
      for (final v in [
        0,
        false,
        'a',
        [1],
        true,
      ]) {
        expect(filled(v), isTrue, reason: '$v');
      }
    });

    test('tap, value and dataGet', () {
      final list = tap(<int>[], (l) => l.add(1));
      expect(list, [1]);
      expect(value(() => 1 + 1), 2);
      final data = {
        'user': {
          'name': 'Ana',
          'roles': ['admin', 'editor'],
        },
      };
      expect(dataGet(data, 'user.name'), 'Ana');
      expect(dataGet(data, 'user.roles.1'), 'editor');
      expect(dataGet(data, 'user.missing', 'n/a'), 'n/a');
      expect(dataGet(data, 'user.roles.9', 'n/a'), 'n/a');
    });

    test('retry retries until success and rethrows the last error', () async {
      var calls = 0;
      final result = await retry(3, (attempt) {
        calls++;
        if (attempt < 3) {
          throw StateError('flaky');
        }
        return 'ok';
      });
      expect(result, 'ok');
      expect(calls, 3);
      await expectLater(
        retry(2, (_) => throw StateError('always')),
        throwsStateError,
      );
      var only = 0;
      await expectLater(
        retry(5, (_) {
          only++;
          throw ArgumentError('no');
        }, when: (e) => e is StateError),
        throwsArgumentError,
      );
      expect(only, 1);
    });

    test('rescue returns the fallback', () async {
      expect(
        await rescue<int>(
          () => throw StateError('x'),
          fallback: 7,
          report: false,
        ),
        7,
      );
      expect(await rescue(() => 1), 1);
    });

    test('once memoizes per scope; now() follows Clock', () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      var runs = 0;
      int compute() => ++runs;
      await app.run(() async {
        expect(once('k', compute), 1);
        expect(once('k', compute), 1);
      });
      await app.run(() async => expect(once('k', compute), 2));

      final frozen = DateTime.utc(2026, 1, 2, 15);
      await Clock.at(frozen, () async {
        expect(now(), frozen);
        expect(today().day, frozen.toLocal().day);
      });
    });

    test('abortIf and abortUnless', () {
      expect(() => abortIf(true, 403), throwsA(isA<HttpException>()));
      abortIf(false, 403);
      expect(
        () => abortUnless(false, 404, 'no'),
        throwsA(isA<HttpException>()),
      );
      abortUnless(true, 404);
    });
  });

  group('Iterable extensions', () {
    final rows = [
      {
        'id': 1,
        'role': 'admin',
        'total': 10,
        'user': {'name': 'Ana'},
      },
      {
        'id': 2,
        'role': 'editor',
        'total': 5,
        'user': {'name': 'Bo'},
      },
      {
        'id': 3,
        'role': 'admin',
        'total': 7,
        'user': {'name': 'Cy'},
      },
    ];

    test('pluck, keyBy and groupBy', () {
      expect(rows.pluck('id'), [1, 2, 3]);
      expect(rows.pluck('user.name'), ['Ana', 'Bo', 'Cy']);
      expect(rows.keyBy((r) => r['id']).keys, [1, 2, 3]);
      final groups = rows.groupBy((r) => r['role']);
      expect(groups.keys, ['admin', 'editor']);
      expect(groups['admin']!.pluck('id'), [1, 3]);
    });

    test('chunk, unique, sums and sorting', () {
      expect([1, 2, 3, 4, 5].chunk(2).toList(), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect([1, 2, 1, 3, 2].unique(), [1, 2, 3]);
      expect(rows.unique((r) => r['role']).pluck('id'), [1, 2]);
      expect(rows.sumBy((r) => r['total']! as int), 22);
      expect(rows.avgBy((r) => r['total']! as int), closeTo(7.33, 0.01));
      expect(<int>[].avgBy((v) => v), isNull);
      expect(rows.sortBy((r) => r['total']! as int).pluck('id'), [2, 3, 1]);
      expect(rows.sortByDesc((r) => r['total']! as int).pluck('id'), [1, 3, 2]);
      final (admins, others) = rows.partition((r) => r['role'] == 'admin');
      expect(admins.pluck('id'), [1, 3]);
      expect(others.pluck('id'), [2]);
    });
  });
}
