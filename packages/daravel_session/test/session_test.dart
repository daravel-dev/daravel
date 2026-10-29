import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

const String appKey = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// The cookie value (URL-decoded) of `set-cookie: name=value; ...`.
String? cookieValue(TestResponse response, String name) {
  for (final line in response.headers.all('set-cookie')) {
    if (line.startsWith('$name=')) {
      final end = line.indexOf(';');
      return Uri.decodeComponent(
        line.substring(name.length + 1, end == -1 ? line.length : end),
      );
    }
  }
  return null;
}

/// Decrypts an encrypted cookie as Laravel's EncryptCookies would read it.
Future<String> decryptCookie(Application app, String name, String value) =>
    app.run(() async {
      final encrypter = Crypt.encrypter;
      final clear = await encrypter.decryptString(value);
      final prefix =
          '${Hmac(sha1, encrypter.key).convert(utf8.encode('${name}v2'))}|';
      expect(clear, startsWith(prefix), reason: 'CookieValuePrefix of $name');
      return clear.substring(prefix.length);
    });

/// Re-encrypts a cookie value the way the browser would send it back.
Future<String> encryptCookie(Application app, String name, String value) =>
    app.run(() async {
      final encrypter = Crypt.encrypter;
      final prefix =
          '${Hmac(sha1, encrypter.key).convert(utf8.encode('${name}v2'))}|';
      return encrypter.encryptString('$prefix$value');
    });

void main() {
  late Directory base;
  late Application app;
  late TestClient client;

  Application build(Map<String, String> env) =>
      Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_NAME': 'My App',
            'APP_KEY': appKey,
            'DB_DATABASE': ':memory:',
            'SESSION_DRIVER': 'array',
            ...env,
          })
          .withLogLevel(LogLevel.warning)
          .withSession(csrfExcept: const ['webhooks/*'])
          .withMigrations(const [CreateSessionsTable()])
          .withRouting(
            web: (router) => router.group((r) {
              r.get('/put', (request) {
                request.session.put('name', 'Jane');
                request.session.flash('status', 'saved');
                return {'id': request.session.id};
              });
              r.get('/get', (request) {
                final session = request.session;
                return {
                  'name': session.get<String>('name'),
                  'status': session.get<String>('status'),
                  'previous': session.previousUrl,
                  'current': identical(Session.current, session),
                };
              });
              r.post('/submit', (request) => {'ok': true});
              r.post('/webhooks/pay', (_) => {'ok': true});
              r.post('/logout', (request) async {
                await request.session.invalidate();
                return {'id': request.session.id};
              });
            }, middleware: const ['web']),
          )
          .create();

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_session');
    app = build(const {});
    await app.boot();
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  group('StartSession + EncryptCookies', () {
    test('the cookie is named after the app, encrypted, with Laravel\'s '
        'prefix, and carries the session across requests', () async {
      final first = await client.get('/put');
      first.assertOk();
      final sessionId = first.jsonMap['id'] as String;
      expect(Session.isValidId(sessionId), isTrue);

      final cookie = cookieValue(first, 'my_app_session')!;
      // Encrypted: not the id itself, but Laravel's Crypt payload...
      expect(cookie, isNot(sessionId));
      expect(
        jsonDecode(utf8.decode(base64.decode(cookie))),
        containsPair('mac', isA<String>()),
      );
      // ...of the prefixed id.
      expect(await decryptCookie(app, 'my_app_session', cookie), sessionId);
      final line = first.headers
          .all('set-cookie')
          .firstWhere((l) => l.startsWith('my_app_session='));
      expect(line, contains('; Max-Age=7200; path=/; httponly; samesite=lax'));

      final second = await client.get(
        '/get',
        headers: {'cookie': 'my_app_session=${Uri.encodeComponent(cookie)}'},
      );
      expect(second.jsonMap, {
        'name': 'Jane',
        'status': 'saved',
        'previous': 'http://localhost/put',
        'current': true,
      });

      // Flash data lives for one request.
      final third = await client.get(
        '/get',
        headers: {'cookie': 'my_app_session=${Uri.encodeComponent(cookie)}'},
      );
      expect(third.jsonMap['status'], isNull);
      expect(third.jsonMap['name'], 'Jane');
    });

    test('a forged or foreign cookie starts a new session', () async {
      final forged = await encryptCookie(app, 'other_name', 'x' * 40);
      final response = await client.get(
        '/get',
        headers: {
          'cookie':
              'my_app_session=${Uri.encodeComponent(forged)}; '
              'plain=${'y' * 40}',
        },
      );
      response.assertOk();
      expect(response.jsonMap['name'], isNull);
      final issued = await decryptCookie(
        app,
        'my_app_session',
        cookieValue(response, 'my_app_session')!,
      );
      expect(issued, isNot('x' * 40));
    });

    test('the payload in the store is what Laravel serializes', () async {
      final response = await client.get('/put');
      final id = response.jsonMap['id'] as String;
      final handler =
          app.container.make<SessionManager>().handler as ArraySessionHandler;
      final payload = handler.payloads[id]!;
      final data = phpUnserialize(payload) as Map<String, Object?>;
      expect(data['name'], 'Jane');
      expect(data['status'], 'saved');
      expect((data['_token'] as String).length, 40);
      expect(data['_flash'], {
        'old': ['status'],
        'new': <Object?>[],
      });
      expect(data['_previous'], {'url': 'http://localhost/put'});
      expect(payload, startsWith('a:'));
    });

    test('invalidate empties the session and changes the id', () async {
      final first = await client.get('/put');
      final cookie = cookieValue(first, 'my_app_session')!;
      final oldId = first.jsonMap['id'] as String;
      final token = await decryptCookie(
        app,
        'XSRF-TOKEN',
        cookieValue(first, 'XSRF-TOKEN')!,
      );
      final logout = await client.post(
        '/logout',
        headers: {
          'cookie': 'my_app_session=${Uri.encodeComponent(cookie)}',
          'x-csrf-token': token,
        },
      );
      logout.assertOk();
      final newId = logout.jsonMap['id'] as String;
      expect(newId, isNot(oldId));
      final handler =
          app.container.make<SessionManager>().handler as ArraySessionHandler;
      expect(handler.payloads.containsKey(oldId), isFalse);
      final data = phpUnserialize(handler.payloads[newId]!) as Map;
      expect(data.containsKey('name'), isFalse);
    });
  });

  group('VerifyCsrfToken', () {
    late String cookie;
    late String xsrfCookie;
    late String token;

    setUp(() async {
      final page = await client.get('/get');
      cookie = cookieValue(page, 'my_app_session')!;
      xsrfCookie = cookieValue(page, 'XSRF-TOKEN')!;
      token = await decryptCookie(app, 'XSRF-TOKEN', xsrfCookie);
      expect(token.length, 40);
      final xsrfLine = page.headers
          .all('set-cookie')
          .firstWhere((l) => l.startsWith('XSRF-TOKEN='));
      // Readable by scripts, as Laravel sets it.
      expect(xsrfLine, isNot(contains('httponly')));
    });

    Map<String, String> withSession([Map<String, String> extra = const {}]) => {
      'cookie': 'my_app_session=${Uri.encodeComponent(cookie)}',
      ...extra,
    };

    test('a POST without a token is 419 CSRF token mismatch.', () async {
      final response = await client.post(
        '/submit',
        json: {'a': 1},
        headers: withSession(),
      );
      expect(response.status, 419);
      expect(response.jsonMap, {'message': 'CSRF token mismatch.'});
    });

    test('_token input, X-CSRF-TOKEN and X-XSRF-TOKEN pass', () async {
      final viaInput = await client.post(
        '/submit',
        json: {'_token': token},
        headers: withSession(),
      );
      viaInput.assertOk();
      final viaHeader = await client.post(
        '/submit',
        json: {},
        headers: withSession({'x-csrf-token': token}),
      );
      viaHeader.assertOk();
      // Axios echoes the XSRF-TOKEN cookie, still encrypted.
      final viaXsrf = await client.post(
        '/submit',
        json: {},
        headers: withSession({'x-xsrf-token': xsrfCookie}),
      );
      viaXsrf.assertOk();
      final wrong = await client.post(
        '/submit',
        json: {},
        headers: withSession({'x-csrf-token': 'x' * 40}),
      );
      expect(wrong.status, 419);
    });

    test('reads and excepted paths skip the check', () async {
      (await client.get('/get', headers: withSession())).assertOk();
      final webhook = await client.post(
        '/webhooks/pay',
        json: {},
        headers: withSession(),
      );
      webhook.assertOk();
    });
  });

  group('database driver', () {
    test('rows are Laravel\'s sessions table', () async {
      await app.shutdown();
      app = build(const {'SESSION_DRIVER': 'database'});
      await app.boot();
      await app.run(() => App.make<Migrator>().run());
      client = TestClient(app);

      final first = await client.get('/put', headers: {'user-agent': 'UA/1'});
      final id = first.jsonMap['id'] as String;
      final row = await app.run(
        () => DB.table('sessions').where('id', id).first(),
      );
      expect(row, isNotNull);
      expect(row!['user_id'], isNull);
      expect(row['ip_address'], '127.0.0.1');
      expect(row['user_agent'], 'UA/1');
      final payload = utf8.decode(base64.decode('${row['payload']}'));
      expect((phpUnserialize(payload) as Map)['name'], 'Jane');
      final lastActivity = row['last_activity'] as int;
      expect(
        lastActivity,
        closeTo(Clock.now().millisecondsSinceEpoch ~/ 1000, 5),
      );

      // A session Laravel wrote: base64(serialize([...])).
      const laravelId = 'LaravelWroteThisSessionIdOfFortyChars123';
      await app.run(
        () => DB.table('sessions').insert({
          'id': laravelId,
          'payload': base64.encode(
            utf8.encode(
              'a:2:{s:6:"_token";s:40:"${'t' * 40}";s:4:"name";s:3:"Joe";}',
            ),
          ),
          'last_activity': Clock.now().millisecondsSinceEpoch ~/ 1000,
        }),
      );
      final laravelCookie = await encryptCookie(
        app,
        'my_app_session',
        laravelId,
      );
      final shared = await client.get(
        '/get',
        headers: {
          'cookie': 'my_app_session=${Uri.encodeComponent(laravelCookie)}',
        },
      );
      expect(shared.jsonMap['name'], 'Joe');

      // Expired rows read as empty.
      await app.run(
        () => DB.table('sessions').where('id', laravelId).update({
          'last_activity':
              Clock.now().millisecondsSinceEpoch ~/ 1000 - 121 * 60,
        }),
      );
      final expired = await client.get(
        '/get',
        headers: {
          'cookie': 'my_app_session=${Uri.encodeComponent(laravelCookie)}',
        },
      );
      expect(expired.jsonMap['name'], isNull);
    });
  });

  group('file driver', () {
    test('one file per session under storage/framework/sessions', () async {
      await app.shutdown();
      app = build(const {'SESSION_DRIVER': 'file'});
      await app.boot();
      client = TestClient(app);
      final first = await client.get('/put');
      final id = first.jsonMap['id'] as String;
      final file = File('${base.path}/storage/framework/sessions/$id');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), startsWith('a:'));
      final cookie = cookieValue(first, 'my_app_session')!;
      final second = await client.get(
        '/get',
        headers: {'cookie': 'my_app_session=${Uri.encodeComponent(cookie)}'},
      );
      expect(second.jsonMap['name'], 'Jane');
    });
  });

  group('Session (unit)', () {
    test('flash, reflash, keep and now follow Laravel', () async {
      final handler = ArraySessionHandler(lifetime: const Duration(hours: 1));
      final session = Session(name: 's', handler: handler);
      await session.start();
      session.flash('a', 1);
      session.now('b', 2);
      expect(session.get<int>('a'), 1);
      expect(session.get<int>('b'), 2);
      await session.save();

      final next = Session(name: 's', handler: handler, id: session.id);
      await next.start();
      expect(next.get<int>('a'), 1, reason: 'flashed to the next request');
      expect(next.has('b'), isFalse, reason: 'now() lasted one request');
      next.reflash();
      await next.save();

      final third = Session(name: 's', handler: handler, id: session.id);
      await third.start();
      expect(third.get<int>('a'), 1, reason: 'reflashed');
      await third.save();

      final fourth = Session(name: 's', handler: handler, id: session.id);
      await fourth.start();
      expect(fourth.has('a'), isFalse);
      expect(fourth.token, isNotNull);
    });

    test('dot keys, pull, push, increment, regenerate', () async {
      final handler = ArraySessionHandler(lifetime: const Duration(hours: 1));
      final session = Session(name: 's', handler: handler);
      await session.start();
      session.put('cart.items', ['a']);
      session.push('cart.items', 'b');
      expect(session.get<List<Object?>>('cart.items'), ['a', 'b']);
      expect(session.all['cart'], {
        'items': ['a', 'b'],
      });
      expect(session.increment('hits'), 1);
      expect(session.increment('hits', 2), 3);
      expect(session.pull<int>('hits'), 3);
      expect(session.has('hits'), isFalse);
      final token = session.token;
      final id = session.id;
      await session.regenerate();
      expect(session.id, isNot(id));
      expect(session.token, isNot(token));
      expect(session.get<List<Object?>>('cart.items'), ['a', 'b']);
    });

    test('an invalid cookie id is replaced', () {
      final handler = ArraySessionHandler(lifetime: const Duration(hours: 1));
      expect(Session(name: 's', handler: handler, id: 'short').id.length, 40);
      expect(
        Session(name: 's', handler: handler, id: '${'a' * 39}!').id,
        isNot('${'a' * 39}!'),
      );
    });
  });

  test('SessionConfig reads Laravel\'s variables', () {
    final config = SessionConfig.fromEnv(
      Env.fromMap(const {
        'APP_NAME': 'Toko Online 2',
        'SESSION_LIFETIME': '30',
        'SESSION_SAME_SITE': 'strict',
        'SESSION_DOMAIN': '.example.test',
      }),
    );
    expect(config.cookie, 'toko_online_2_session');
    expect(config.lifetime, const Duration(minutes: 30));
    expect(config.sameSite, 'strict');
    expect(config.domain, '.example.test');
    expect(
      SessionConfig.fromEnv(Env.fromMap(const {})).cookie,
      'daravel_session',
    );
  });
}
