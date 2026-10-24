@Tags(['security'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../conformance/conformance_app.dart';

/// Security regression suite (BLUEPRINT_V2 §9.3): injection, spoofing,
/// limits, token manipulation, traversal, ReDoS and parser fuzzing.
void main() {
  group('SQL injection (OWASP payloads stay data)', () {
    late Application app;
    late TestClient client;

    setUp(() async {
      (app, client) = await bootConformanceApp();
      await seedPosts(app, 3);
    });
    tearDown(() => app.shutdown());

    const payloads = <String>[
      "' OR '1'='1",
      "' OR 1=1 --",
      '" OR ""="',
      "'; DROP TABLE posts; --",
      "1' UNION SELECT name, password FROM users --",
      "admin'/*",
      r"\'; DELETE FROM posts WHERE 1=1; --",
      "' AND SLEEP(5) --",
      '%27%20OR%201=1',
    ];

    test('as bound values in where/whereRaw/insert', () async {
      for (final payload in payloads) {
        final rows = await app.run(
          () => DB.table('posts').where('title', payload).get(),
        );
        expect(rows, isEmpty, reason: payload);
        final raw = await app.run(
          () => DB.table('posts').whereRaw('title = ?', [payload]).get(),
        );
        expect(raw, isEmpty, reason: payload);
        await app.run(() => DB.table('posts').insert({'title': payload}));
      }
      final titles = await app.run(
        () async => [
          for (final row in await DB.table('posts').orderBy('id').get())
            row['title'],
        ],
      );
      expect(titles.skip(3), payloads, reason: 'stored verbatim');
    });

    test('as identifiers they are quoted, never executed', () async {
      for (final payload in payloads) {
        await expectLater(
          app.run(() => DB.table('posts').orderBy(payload).get()),
          throwsA(anything),
          reason: payload,
        );
      }
      final count = await app.run(() => DB.table('posts').count());
      expect(count, 3, reason: 'table intact');
    });

    test('through the HTTP layer', () async {
      for (final payload in payloads) {
        final res = await client.get(
          '/api/posts?page=${Uri.encodeQueryComponent(payload)}',
        );
        res.assertOk();
        expect(res.jsonMap['current_page'], 1);
      }
    });
  });

  group('X-Forwarded-* spoofing', () {
    Future<Request> through(Middleware middleware, Request request) async {
      Request? seen;
      await middleware.handle(request, (r) async {
        seen = r;
        return Response.noContent();
      });
      return seen!;
    }

    Request spoofed(String peer) => Request.fake(
      ip: peer,
      headers: {
        'x-forwarded-for': '6.6.6.6',
        'x-forwarded-proto': 'https',
        'x-forwarded-host': 'evil.example',
      },
    );

    test('ignored without trusted proxies (default)', () async {
      final r = await through(TrustProxiesMiddleware(), spoofed('203.0.113.9'));
      expect(r.ip, '203.0.113.9');
      expect(r.scheme, 'http');
      expect(r.host, 'localhost');
    });

    test('ignored from a peer outside the trusted CIDR', () async {
      final r = await through(
        TrustProxiesMiddleware(proxies: ['10.0.0.0/8']),
        spoofed('203.0.113.9'),
      );
      expect(r.ip, '203.0.113.9');
      expect(r.host, 'localhost');
    });

    test('honoured from a trusted proxy', () async {
      final r = await through(
        TrustProxiesMiddleware(proxies: ['10.0.0.0/8']),
        spoofed('10.1.2.3'),
      );
      expect(r.ip, '6.6.6.6');
      expect(r.isSecure, isTrue);
    });
  });

  group('request limits', () {
    late Application app;
    late TestClient client;

    setUp(() async => (app, client) = await bootConformanceApp());
    tearDown(() => app.shutdown());

    test('declared oversized body → 413 before reading it', () async {
      final res = await client.send(
        'POST',
        '/api/echo',
        body: 'x' * 4096,
        headers: {'content-type': 'application/json'},
      );
      res.assertStatus(413);
    });

    test('streamed body beyond the limit is cut off', () async {
      final request = Request.fake(method: 'POST', body: 'y' * 5000)
        ..maxBodyBytes = 100;
      request.headers.remove('content-length');
      await expectLater(
        request.bytes(),
        throwsA(isA<PayloadTooLargeHttpException>()),
      );
    });

    test('deeply nested JSON is rejected', () async {
      final nested = '${'[' * 200}${']' * 200}';
      final request = Request.fake(
        method: 'POST',
        body: nested,
        headers: {'content-type': 'application/json'},
      )..maxJsonDepth = 64;
      await expectLater(request.all(), throwsA(isA<HttpException>()));
    });
  });

  group('JWT manipulation', () {
    final codec = JwtCodec.hs256('s3cret-s3cret-s3cret-s3cret-s3cret!');
    String b64(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

    test('alg "none" is rejected', () async {
      final token = '${b64({'alg': 'none', 'typ': 'JWT'})}.${b64({'sub': 1})}.';
      await expectLater(codec.verify(token), throwsA(isA<JwtException>()));
    });

    test('changing alg to one without a configured key fails', () async {
      final valid = await codec.sign({'sub': 1});
      final parts = valid.split('.');
      final forged =
          '${b64({'alg': 'HS512', 'typ': 'JWT'})}.${parts[1]}.${parts[2]}';
      await expectLater(codec.verify(forged), throwsA(isA<JwtException>()));
    });

    test('HS256 forged with an Ed25519 public key is rejected', () async {
      final ed = await Ed25519JwtKey.generate();
      final edCodec = JwtCodec(keys: [Ed25519JwtKey(publicKey: ed.publicKey)]);
      // Classic key confusion: HMAC "secret" = the public key bytes.
      final attacker = JwtCodec(keys: [HmacJwtKey(ed.publicKey)]);
      final forged = await attacker.sign({'sub': 1});
      await expectLater(edCodec.verify(forged), throwsA(isA<JwtException>()));
    });

    test('tampered payload and expired tokens are rejected', () async {
      final valid = await codec.sign({'sub': 1});
      final parts = valid.split('.');
      final tampered = '${parts[0]}.${b64({'sub': 2})}.${parts[2]}';
      await expectLater(codec.verify(tampered), throwsA(isA<JwtException>()));
      final expired = await codec.sign({
        'sub': 1,
        'exp': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 3600,
      });
      await expectLater(codec.verify(expired), throwsA(isA<JwtException>()));
    });
  });

  group('expired personal access tokens', () {
    test('are rejected even with a valid secret', () async {
      final (app, client) = await bootConformanceApp();
      addTearDown(app.shutdown);
      final user = await app.run(
        () => User.definition.query().create({
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': 'x',
        }),
      );
      final issued = await app.run(
        () => Auth.issueToken(
          user,
          'short',
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 1),
          ),
        ),
      );
      (await client.withToken(issued.plainTextToken).get('/api/me'))
          .assertUnauthorized();
    });
  });

  group('user enumeration', () {
    test('unknown e-mails cost a hash, like wrong passwords', () async {
      final (app, _) = await bootConformanceApp(env: {'BCRYPT_ROUNDS': '10'});
      addTearDown(app.shutdown);
      await app.run(
        () async => User.definition.query().create({
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': await Hash.make('right-password'),
        }),
      );
      Future<int> attempt(String email) async {
        final watch = Stopwatch()..start();
        final user = await app.run(
          () => Auth.retrieveByCredentials<User>({
            'email': email,
            'password': 'wrong-password',
          }),
        );
        expect(user, isNull);
        return watch.elapsedMicroseconds;
      }

      await attempt('nobody@example.com'); // Builds the dummy hash once.
      final known = await attempt('ana@example.com');
      final unknown = await attempt('nobody@example.com');
      expect(
        unknown,
        greaterThan(known ~/ 2),
        reason: 'unknown $unknown µs vs known $known µs',
      );
    });
  });

  group('storage path traversal', () {
    late Directory root;
    late LocalDisk disk;

    setUp(() {
      root = Directory.systemTemp.createTempSync('daravel_sec_');
      disk = LocalDisk('local', root.path);
    });
    tearDown(() => root.deleteSync(recursive: true));

    for (final path in [
      '../escape.txt',
      'a/../../escape.txt',
      r'..\escape.txt',
      '/etc/passwd',
      r'C:\Windows\win.ini',
      'a/b/../../../escape.txt',
    ]) {
      test('rejects $path', () async {
        await expectLater(
          disk.put(path, 'x'),
          throwsA(isA<StorageException>()),
        );
        await expectLater(disk.get(path), throwsA(isA<StorageException>()));
      });
    }

    test('normalises harmless dot segments inside the root', () async {
      await disk.put('a/./b/../c.txt', 'ok');
      expect(await disk.get('a/c.txt'), 'ok');
    });
  });

  group('header injection', () {
    test('CR/LF in header values is rejected', () {
      expect(
        () => Response.json({}).withHeader('x-a', 'v\r\nSet-Cookie: s=1'),
        throwsArgumentError,
      );
      expect(() => Headers().set('x-a', 'line\nbreak'), throwsArgumentError);
      expect(() => Headers().set('bad name', 'v'), throwsArgumentError);
    });

    test('a handler that tries it gets a 500, not a split response', () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) => r.get(
              '/redirect',
              (req) => Response.redirect('/x\r\nSet-Cookie: session=evil'),
            ),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final res = await TestClient(app).get('/api/redirect');
      res.assertServerError();
      expect(res.headers.has('set-cookie'), isFalse);
    });
  });

  group('ReDoS: built-in pattern rules on adversarial input', () {
    // Each pattern is repeated to the requested length, so the same shape
    // can be timed at 20 KB and 100 KB.
    final shapes = <String, String Function(int length)>{
      'letters': (n) => 'a' * n,
      'letters+bang': (n) => '${'a' * n}!',
      'at-runs': (n) => '${'a@' * (n ~/ 2)}!',
      'dots': (n) => '${'a.' * (n ~/ 2)}!',
      'dashes': (n) => '${'-' * n}!',
      'email-domain': (n) => 'a@${'a' * (n - 10)}.!',
      'hex': (n) => '${'0' * n}g',
      'unicode': (n) => '${'é' * n}1',
    };
    const rules = [
      'email',
      'url',
      'uuid',
      'ulid',
      'ip',
      'ipv4',
      'ipv6',
      'alpha',
      'alpha_num',
      'alpha_dash',
      'ascii',
      'lowercase',
      'uppercase',
      'json',
      'integer',
      'numeric',
      'digits:5',
      'date',
    ];
    // BLUEPRINT_V2 §9.3 budget (< 10 ms at 100 KB) depends on the machine,
    // so it is enforced only with DARAVEL_STRICT_TIMING=1. Always enforced:
    // time grows linearly with the input (a backtracking blow-up grows at
    // least quadratically) and stays far from a hang.
    final strict = Platform.environment['DARAVEL_STRICT_TIMING'] == '1';

    Future<int> medianMicros(String input, String rule) async {
      await Validator({'v': input}, {'v': rule}).fails(); // Warm-up (JIT).
      final times = <int>[];
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        await Validator({'v': input}, {'v': rule}).fails();
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      return times[2];
    }

    for (final rule in rules) {
      test('$rule scales linearly on 100 KB input', () async {
        for (final MapEntry(key: label, value: shape) in shapes.entries) {
          final small = await medianMicros(shape(20000), rule);
          final large = await medianMicros(shape(100000), rule);
          final reason = '$rule on $label: 20 KB $small µs, 100 KB $large µs';
          expect(large, lessThan(250000), reason: reason);
          // 5x the input: linear ≈ 5x, quadratic ≈ 25x. Sub-millisecond
          // timings are noise, so the ratio is only checked above 1 ms.
          if (large > 1000) {
            expect(
              large / (small < 50 ? 50 : small),
              lessThan(15),
              reason: reason,
            );
          }
          if (strict) {
            expect(large, lessThan(10000), reason: reason);
          }
        }
      });
    }
  });

  group('fuzzing (seeded, property based)', () {
    final random = Random(20261024);
    String noise(int maxLength) {
      const alphabet =
          'abcAZ09 =#"\'\\\$\n\r\t{}[]()*,/-.:;?@!%^&|~`<>_+\u00e9\u0000';
      final length = random.nextInt(maxLength);
      return String.fromCharCodes([
        for (var i = 0; i < length; i++)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
    }

    test('.env parser only throws EnvException', () {
      for (var i = 0; i < 2000; i++) {
        try {
          Env.parse(noise(200));
        } on EnvException {
          // Invalid files are refused, like phpdotenv.
        }
      }
    });

    test('cron parser only throws CronFormatException', () {
      const parts = ['*', '*/5', '1-3', '1,2', '61', '-1', 'a', '', '?', 'L'];
      for (var i = 0; i < 2000; i++) {
        final expression = [
          for (var f = 0; f < 3 + random.nextInt(4); f++)
            parts[random.nextInt(parts.length)],
        ].join(' ');
        try {
          CronExpression.parse(expression);
        } on CronFormatException {
          // Expected for invalid input.
        }
      }
    });

    test('cursor decoder returns null instead of throwing', () {
      for (var i = 0; i < 2000; i++) {
        Cursor.decode(noise(80));
      }
    });

    test('JSON body parser only throws HTTP exceptions', () async {
      for (var i = 0; i < 500; i++) {
        final request = Request.fake(
          method: 'POST',
          body: noise(120),
          headers: {'content-type': 'application/json'},
        );
        try {
          await request.all();
        } on HttpException {
          // 400/413 for malformed bodies.
        }
      }
    });

    test('bearer tokens of any shape never crash the token guard', () async {
      final (app, client) = await bootConformanceApp();
      addTearDown(app.shutdown);
      for (var i = 0; i < 200; i++) {
        final token = noise(60).replaceAll(RegExp(r'[\r\n\u0000]'), '');
        final res = await client.withToken(token).get('/api/me');
        expect(res.status, 401, reason: jsonEncode(token));
      }
    });
  });
}
