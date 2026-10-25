import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/translation/plural_rules.g.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Every expectation in the fixture is the output of Laravel's own
/// Translator and MessageSelector (`tool/translation/laravel_fixture.php`).
final Map<String, Object?> laravel = jsonDecode(
  File('test/translation/laravel_translation_fixture.json').readAsStringSync(),
) as Map<String, Object?>;

Map<String, Object?> _replace(Object? values) => switch (values) {
  final Map<String, Object?> map => map,
  _ => const {}, // PHP encodes an empty array as [].
};

void main() {
  test('plural index matches Laravel for every locale and number', () {
    final numbers = (laravel['numbers']! as List).cast<num>();
    final table = laravel['pluralIndex']! as Map<String, Object?>;
    expect(table, hasLength(280));
    for (final MapEntry(key: locale, value: indices) in table.entries) {
      final expected = (indices! as List).cast<int>();
      expect(
        [for (final n in numbers) pluralIndex(locale, n)],
        expected,
        reason: locale,
      );
    }
    expect(pluralIndex('xx_unknown', 5), 0);
  });

  test('choose matches MessageSelector::choose', () {
    for (final entry in (laravel['choose']! as List).cast<List<Object?>>()) {
      final [line as String, number as num, locale as String, expected] = entry;
      expect(
        Translator.choose(line, number, locale),
        expected,
        reason: '"$line" with $number in $locale',
      );
    }
  });

  test('placeholders are replaced as Laravel does (strtr semantics)', () {
    for (final entry
        in (laravel['replacements']! as List).cast<List<Object?>>()) {
      final [line as String, values, expected] = entry;
      final replace = _replace(values);
      // PHP prints 12.5 as "12.5" and null as "": the same as Dart here.
      expect(
        Translator.makeReplacements(line, replace),
        expected,
        reason: line,
      );
    }
  });

  group('get and choice', () {
    late Translator translator;
    setUp(() {
      translator = Translator()
        ..addLines({
          'messages': {
            'welcome': 'Welcome, :name!',
            'shout': ':NAME and :Name and :name',
            'overlap': ':name / :named / :name_full',
            'only_en': 'English only',
            'minutes': '{1} :count minute left|[2,*] :count minutes left',
            'apples': 'apple|apples',
          },
        }, 'en')
        ..addLines({
          'messages.welcome': 'Selamat datang, :name!',
          'messages.minutes': ':count menit tersisa',
        }, 'id');
    });

    test('get falls back to the fallback locale, then the key', () {
      for (final entry in (laravel['get']! as List).cast<List<Object?>>()) {
        final [key as String, values, locale as String, expected] = entry;
        expect(
          translator.get(key, replace: _replace(values), locale: locale),
          expected,
          reason: '$key in $locale',
        );
      }
    });

    test('choice fills :count and uses the plural rules of the line', () {
      for (final entry in (laravel['choice']! as List).cast<List<Object?>>()) {
        final [key as String, count as num, locale as String, expected] = entry;
        expect(
          translator.choice(key, count, locale: locale),
          expected,
          reason: '$key x$count in $locale',
        );
      }
    });

    test('JSON lines win in their locale and do not fall back', () {
      translator
        ..addJson({'Log in': 'Masuk', 'messages.welcome': 'Halo :name'}, 'id')
        ..addJson({'Only English JSON': 'yes'}, 'en');
      expect(translator.get('Log in', locale: 'id'), 'Masuk');
      expect(
        translator.get(
          'messages.welcome',
          replace: {'name': 'A'},
          locale: 'id',
        ),
        'Halo A',
      );
      expect(
        translator.get('Only English JSON', locale: 'id'),
        'Only English JSON',
      );
      expect(translator.has('Log in', locale: 'id'), isTrue);
      expect(translator.has('Log in', locale: 'en'), isFalse);
    });
  });

  group('in an application', () {
    late Directory base;
    late Application app;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_lang_');
      Directory('${base.path}/lang').createSync();
      File('${base.path}/lang/id.json')
          .writeAsStringSync(jsonEncode({'Log in': 'Masuk'}));
      app = Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_LOCALE': 'id',
            'DB_DATABASE': ':memory:',
          })
          .withTranslations({
            'en': {'greeting': 'Hello, :name'},
            'id': {'greeting': 'Halo, :name'},
          })
          .withRouting(
            api: (router) {
              router.get(
                '/greet',
                (_) => {
                  'text': trans('greeting', {'name': 'Teo'}),
                  'locale': App.locale,
                  'login': trans('Log in'),
                },
              );
              router.post('/check', (_) => null).rules(const {
                'email': 'required',
              });
            },
          )
          .withMiddleware((middleware) {
            middleware.use(const [
              SetLocaleMiddleware(supported: ['en', 'id']),
            ]);
          })
          .create();
      await app.boot();
    });

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    test('APP_LOCALE, lang/*.json and the facade', () async {
      await app.run(() async {
        expect(App.locale, 'id');
        expect(trans('greeting', {'name': 'A'}), 'Halo, A');
        expect(trans('Log in'), 'Masuk');
        expect(Lang.get('greeting', {'name': 'A'}, 'en'), 'Hello, A');
        expect(transChoice('missing.key', 2), 'missing.key');
      });
    });

    test(
      'each request has its own locale (query, then Accept-Language)',
      () async {
        final client = TestClient(app);
        final responses = await Future.wait([
          client.get('/api/greet?lang=en'),
          client.get(
            '/api/greet',
            headers: {'accept-language': 'en-GB,id;q=0.5'},
          ),
          client.get(
            '/api/greet',
            headers: {'accept-language': 'fr, de;q=0.9'},
          ),
          client.get('/api/greet'),
        ]);
        expect(
          [for (final r in responses) jsonDecode(r.body)],
          [
            {'text': 'Hello, Teo', 'locale': 'en', 'login': 'Log in'},
            {'text': 'Hello, Teo', 'locale': 'en', 'login': 'Log in'},
            {'text': 'Halo, Teo', 'locale': 'id', 'login': 'Masuk'},
            {'text': 'Halo, Teo', 'locale': 'id', 'login': 'Masuk'},
          ],
        );
      },
    );

    test('validation messages follow the request locale', () async {
      final client = TestClient(app);
      final english = await client.post('/api/check?lang=en', json: const {});
      final indonesian = await client.post('/api/check', json: const {});
      english.assertStatus(422);
      expect(
        jsonDecode(english.body),
        containsPair('message', 'The email field is required.'),
      );
      expect(
        (jsonDecode(indonesian.body) as Map)['message'],
        isNot('The email field is required.'),
      );
    });
  });

  test('Accept-Language negotiation', () {
    const supported = ['en', 'id', 'pt_BR'];
    String? pick(String? header) =>
        SetLocaleMiddleware.negotiate(header, supported);
    expect(pick('id-ID,id;q=0.9,en;q=0.8'), 'id');
    expect(pick('en;q=0.2, id;q=0.8'), 'id');
    expect(pick('pt-BR'), 'pt_BR');
    expect(pick('fr, *;q=0.5'), isNull);
    expect(pick('id;q=0, en'), 'en');
    expect(pick(null), isNull);
    expect(SetLocaleMiddleware.match('ID', supported), 'id');
  });
}
