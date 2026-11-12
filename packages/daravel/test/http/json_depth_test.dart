import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/json_nesting.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// A JSON body nested as deep as PHP's `json_decode` depth (512) or deeper
/// is read as no input at all, as Laravel 13 reads it: `Request::json()`
/// is `(array) json_decode($content, true)`, and past the depth that is
/// `(array) null`, `[]`. 511 nested levels are read; 512 are not.
///
/// The golden (`fixtures/laravel_json_depth.json`) was run through
/// Laravel 13.40 on PHP 8.3: for each body, whether `$request->all()` held
/// anything and whether `['a' => 'required']` failed.
void main() {
  final golden =
      (jsonDecode(
            File('test/http/fixtures/laravel_json_depth.json')
                .readAsStringSync(),
          ) as Map<String, Object?>)['cases']!
          as List<Object?>;
  final cases = [
    for (final c in golden.cast<Map<String, Object?>>())
      (
        shape: c['shape']! as String,
        levels: c['levels']! as int,
        leaf: c['leaf']! as String,
        read: c['read']! as bool,
        requiredFails: c['required_a_fails']! as bool,
      ),
  ];

  // The golden's shapes, as golden.php builds them.
  String body(String shape, int levels, String leaf) => switch (shape) {
    'arrays' => '${'[' * levels}$leaf${']' * levels}',
    'objects' => '${'{"a":' * levels}$leaf${'}' * levels}',
    'object_arrays' => '{"a":${'[' * (levels - 1)}$leaf${']' * (levels - 1)}}',
    'mixed' => () {
      final open = StringBuffer();
      var close = '';
      for (var i = 0; i < levels; i++) {
        open.write(i.isEven ? '{"a":' : '[');
        close = (i.isEven ? '}' : ']') + close;
      }
      return '$open$leaf$close';
    }(),
    _ => throw ArgumentError(shape),
  };

  String label(
    ({String shape, int levels, String leaf, bool read, bool requiredFails}) c,
  ) =>
      '${c.shape} ${c.levels} levels, '
      'leaf ${c.leaf.isEmpty ? '(none)' : c.leaf}';

  test('the golden covers both sides of the depth', () {
    expect(cases, hasLength(greaterThan(80)));
    expect(cases.where((c) => c.levels == 511 && c.read), isNotEmpty);
    expect(cases.where((c) => c.levels == 512 && !c.read), isNotEmpty);
    expect(cases.where((c) => c.levels >= 512 && c.read), isEmpty);
  });

  group('Request.body against Laravel 13', () {
    test('every golden case', () async {
      final wrong = <String>[];
      for (final c in cases) {
        final request = Request.fake(
          method: 'POST',
          body: body(c.shape, c.levels, c.leaf),
          headers: {'content-type': 'application/json'},
        );
        // The decoded body, as Laravel's `json()` holds it: a list at the
        // top counts too (Laravel's `all()` keys it 0, 1, …, where
        // Daravel's merged input reads only a map; a separate difference).
        final read = switch (await request.body()) {
          final Map<String, Object?> map => map.isNotEmpty,
          final List<Object?> list => list.isNotEmpty,
          _ => false,
        };
        if (read != c.read) {
          wrong.add('${label(c)}: read $read');
        }
      }
      expect(wrong, isEmpty);
    });

    test('512 is the default, with the meaning of PHP\'s depth', () async {
      expect(Request.defaultJsonMaxDepth, 512);
      Future<Map<String, Object?>> read(int levels, {int? depth}) {
        final request = Request.fake(
          method: 'POST',
          body: body('object_arrays', levels, '1'),
          headers: {'content-type': 'application/json'},
        );
        if (depth != null) {
          request.jsonMaxDepth = depth;
        }
        return request.all();
      }

      expect(await read(511), contains('a'));
      expect(await read(512), isEmpty);
      expect(await read(3, depth: 4), contains('a'));
      expect(await read(4, depth: 4), isEmpty);
      // A body as long as the limit, all of it opening brackets: counted
      // (a shorter one cannot nest that deep and is not).
      final opens = Request.fake(
        method: 'POST',
        body: '[[[[',
        headers: {'content-type': 'application/json'},
      )..jsonMaxDepth = 4;
      expect(await opens.body(), <String, Object?>{});
    });

    test('null turns the limit off', () async {
      final request = Request.fake(
        method: 'POST',
        body: body('object_arrays', 2000, '1'),
        headers: {'content-type': 'application/json'},
      )..jsonMaxDepth = null;
      expect(await request.all(), contains('a'));
    });

    test('the raw body stays as sent', () async {
      final sent = body('arrays', 600, '1');
      final request = Request.fake(
        method: 'POST',
        body: sent,
        headers: {'content-type': 'application/json'},
      );
      expect(await request.all(), isEmpty);
      expect(utf8.decode(await request.bytes()), sent);
    });

    test('form and multipart bodies are not counted', () async {
      // Brackets in a form body are text (or PHP's array keys), never JSON.
      final brackets = Uri.encodeQueryComponent('[' * 2000);
      final form = Request.fake(
        method: 'POST',
        body: 'a=$brackets&b=1',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      );
      expect(await form.all(), {'a': '[' * 2000, 'b': '1'});
      const boundary = 'xyz';
      final multipart = Request.fake(
        method: 'POST',
        body:
            '--$boundary\r\n'
            'Content-Disposition: form-data; name="a"\r\n\r\n'
            '${'[' * 2000}\r\n'
            '--$boundary--\r\n',
        headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      );
      expect(await multipart.all(), {'a': '[' * 2000});
    });

    test('BodyLimitsMiddleware still refuses past its depth, without '
        'recursion', () async {
      // `maxJsonDepth` (the middleware's 64) answers 400; the nesting is
      // counted on the bytes, so a body far deeper than any stack is
      // refused, not a 500.
      for (final levels in [65, 600, 200000]) {
        final request = Request.fake(
          method: 'POST',
          body: body('arrays', levels, '1'),
          headers: {'content-type': 'application/json'},
        )..maxJsonDepth = 64;
        await expectLater(
          request.all(),
          throwsA(isA<BadRequestHttpException>()),
          reason: '$levels',
        );
      }
      final within = Request.fake(
        method: 'POST',
        body: body('object_arrays', 64, '1'),
        headers: {'content-type': 'application/json'},
      )..maxJsonDepth = 64;
      expect(await within.all(), contains('a'));
    });
  });

  group('HTTP_JSON_MAX_DEPTH', () {
    test('unset is 512, 0 no limit, negative an error', () {
      expect(Request.jsonMaxDepthFromEnv(Env.fromMap(const {})), 512);
      expect(
        Request.jsonMaxDepthFromEnv(
          Env.fromMap(const {'HTTP_JSON_MAX_DEPTH': '64'}),
        ),
        64,
      );
      expect(
        Request.jsonMaxDepthFromEnv(
          Env.fromMap(const {'HTTP_JSON_MAX_DEPTH': '0'}),
        ),
        isNull,
      );
      expect(
        () => Request.jsonMaxDepthFromEnv(
          Env.fromMap(const {'HTTP_JSON_MAX_DEPTH': '-1'}),
        ),
        throwsArgumentError,
      );
    });
  });

  group('the test client and the socket answer alike', () {
    late Application app;
    late TestClient client;
    late ServerEngine engine;
    late HttpClient http;

    Future<void> start(Map<String, String> env) async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) {
              router.post('/probe', (request) async {
                await request.validate({'a': 'required'});
                return {'ok': true};
              });
            },
          )
          .create();
      await app.boot();
      client = TestClient(app);
      engine = ServerEngine(
        app,
        ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(minimumLevel: .critical),
      );
      await engine.start();
      http = HttpClient();
    }

    Future<void> stop() async {
      http.close(force: true);
      await engine.stop();
      await app.shutdown();
    }

    Future<int> socket(String sent) async {
      final request = await http.post('127.0.0.1', engine.port!, '/probe');
      request.headers
        ..contentType = ContentType.json
        ..set('accept', 'application/json');
      request.write(sent);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    Future<int> testClient(String sent) async => (await client.send(
      'POST',
      '/probe',
      body: sent,
      headers: {
        'content-type': 'application/json',
        'accept': 'application/json',
      },
    )).status;

    test('every golden case, by both paths', () async {
      await start(const {});
      addTearDown(stop);
      final wrong = <String>[];
      for (final c in cases) {
        final sent = body(c.shape, c.levels, c.leaf);
        final expected = c.requiredFails ? 422 : 200;
        final viaClient = await testClient(sent);
        final viaSocket = await socket(sent);
        if (viaClient != expected || viaSocket != expected) {
          wrong.add(
            '${label(c)}: client $viaClient, socket $viaSocket, '
            'Laravel $expected',
          );
        }
      }
      expect(wrong, isEmpty);
    });

    test('HTTP_JSON_MAX_DEPTH reaches both paths', () async {
      await start(const {'HTTP_JSON_MAX_DEPTH': '8'});
      addTearDown(stop);
      final seven = body('object_arrays', 7, '1');
      final eight = body('object_arrays', 8, '1');
      expect(await testClient(seven), 200);
      expect(await socket(seven), 200);
      expect(await testClient(eight), 422);
      expect(await socket(eight), 422);
    });
  });

  group('jsonNesting', () {
    int nesting(String text, {int? stopAt}) =>
        jsonNesting(utf8.encode(text), stopAt: stopAt);

    test('counts arrays and objects, not scalars', () {
      expect(nesting('1'), 0);
      expect(nesting('"a"'), 0);
      expect(nesting('[]'), 1);
      expect(nesting('{"a":1}'), 1);
      expect(nesting('{"a":[1,{"b":[]}],"c":[]}'), 4);
      expect(nesting('[[1],[[2]],[3]]'), 3);
    });

    test('brackets and escaped quotes inside strings do not count', () {
      expect(nesting(r'{"a":"[[[{{{"}'), 1);
      expect(nesting(r'{"a":"\"[[[","b":"\\"}'), 1);
      expect(nesting(r'["\\\"[",["x"]]'), 2);
      expect(nesting(r'["[["]'), 1);
      expect(nesting('["é[ü", {"ø": "😀{"}]'), 2);
    });

    test('unbalanced text counts as it opens', () {
      expect(nesting('[[[['), 4);
      expect(nesting(']]]]'), 0);
      expect(nesting('[]][['), 2);
    });

    test('stops once the nesting reaches stopAt', () {
      expect(nesting('[[[[[1]]]]]', stopAt: 3), 3);
      expect(nesting('[[1]]', stopAt: 3), 2);
    });

    test('linear in the length, whatever the nesting', () {
      // n against 4n, the fastest of three runs, under 10x.
      Duration time(List<int> bytes) {
        var best = const Duration(days: 1);
        for (var run = 0; run < 3; run++) {
          final watch = Stopwatch()..start();
          jsonNesting(bytes);
          watch.stop();
          if (watch.elapsed < best) {
            best = watch.elapsed;
          }
        }
        return best;
      }

      for (final shape in <List<int> Function(int n)>[
        (n) => utf8.encode('${'[' * n}${']' * n}'),
        (n) => utf8.encode('[${'"\\"[{",' * n}1]'),
        (n) => utf8.encode('${'{"a":[' * n}1${']}' * n}'),
      ]) {
        final small = time(shape(250000));
        final large = time(shape(1000000));
        final ratio = large.inMicroseconds / (small.inMicroseconds + 1);
        expect(ratio, lessThan(10), reason: '$small -> $large');
      }
    });
  });
}
