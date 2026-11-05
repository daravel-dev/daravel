import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Member extends Model with AuthenticatableModel {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;
}

Application build() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'APP_KEY': 'base64:${'A' * 43}=',
        })
        .withLogLevel(LogLevel.warning)
        .withAuth(
          (auth) => auth.viaRequest<Member>('header', (request) {
            final id = request.header('x-member');
            return id == null ? null : (Member()..setAttr('id', int.parse(id)));
          }),
        )
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.get(
              '/cookies',
              (request) => {
                'cookies': request.cookies,
                'accept': request.header('accept'),
              },
            );
            router.get(
              '/admin/cookies',
              (request) => {'cookies': request.cookies},
            );
            router.post(
              '/echo',
              (request) => {
                'xsrf': request.header('x-xsrf-token'),
                'cookie': request.header('cookie'),
              },
            );
            router.get(
              '/set',
              (request) => Response.json({'ok': true})
                  .withCookie(
                    'theme',
                    'dark mode',
                    maxAge: const Duration(hours: 1),
                  )
                  .withCookie('XSRF-TOKEN', 'abc=', httpOnly: false)
                  .withCookie('scoped', 'yes', path: '/admin'),
            );
            router.get(
              '/forget',
              (request) => Response.json({'ok': true}).withoutCookie('theme'),
            );
            router.get('/hop/1', (request) => Response.redirect('/hop/2'));
            router.get(
              '/hop/2',
              (request) =>
                  Response.redirect('http://localhost/hop/3?x=1', status: 301),
            );
            router.get('/hop/3', (request) => {'query': request.uri.query});
            router.post(
              '/form',
              (request) => Response.redirect('/hop/3', status: 303),
            );
            router.get('/loop', (request) => Response.redirect('/loop'));
            router.get(
              '/who',
              (request) async => {'id': await Auth.guard('header').id()},
            );
            router.get('/nobody', (request) => {'ok': true});
          },
        )
        .create();

void main() {
  for (final transport in TestTransport.values) {
    group('${transport.name}:', () {
      late Application app;
      late TestClient client;

      setUp(() async {
        app = build();
        await app.boot();
        client = TestClient(app, transport: transport);
      });

      tearDown(() => app.shutdown());

      test('a browser keeps cookies, sends them back and drops deleted '
          'ones', () async {
        final browser = client.browser();
        (await browser.get('/set'))
            .assertCookie('theme')
            .assertPlainCookie('theme', 'dark mode')
            .assertCookieNotExpired('theme')
            .assertCookieMissing('session');
        expect(browser.cookieJar!.all, {
          'theme': 'dark mode',
          'XSRF-TOKEN': 'abc=',
          'scoped': 'yes',
        });

        final page = await browser.get('/cookies');
        expect(page.jsonMap['cookies'], {
          'theme': 'dark mode',
          'XSRF-TOKEN': 'abc=',
        });
        expect(page.jsonMap['accept'], TestClient.browserAccept);
        expect(
          (await browser.get('/admin/cookies')).jsonMap['cookies'],
          containsPair('scoped', 'yes'),
        );

        (await browser.get('/forget')).assertCookieExpired('theme');
        expect(browser.cookieJar!['theme'], isNull);
        expect((await browser.get('/cookies')).jsonMap['cookies'], {
          'XSRF-TOKEN': 'abc=',
        });

        // A plain client keeps nothing and asks for JSON.
        final plain = await client.get('/cookies');
        expect(plain.jsonMap['cookies'], isEmpty);
        expect(plain.jsonMap['accept'], 'application/json');
      });

      test(
        'the XSRF-TOKEN cookie goes back as X-XSRF-TOKEN on writes only',
        () async {
          final browser = client.browser();
          await browser.get('/set');
          final echo = await browser.post('/echo', form: {'a': 'b'});
          expect(echo.jsonMap['xsrf'], 'abc=');

          final off = client.browser(xsrf: false);
          await off.get('/set');
          expect((await off.post('/echo')).jsonMap['xsrf'], isNull);

          // An explicit header wins.
          final own = await browser.post(
            '/echo',
            headers: {'x-xsrf-token': 'mine'},
          );
          expect(own.jsonMap['xsrf'], 'mine');
        },
      );

      test('cookies expire with Clock.now()', () async {
        final browser = client.browser();
        await browser.get('/set');
        travel(const Duration(hours: 2));
        expect(browser.cookieJar!['theme'], isNull);
        expect(browser.cookieJar!['XSRF-TOKEN'], 'abc=');
      });

      test('withUnencryptedCookie sends the value as it is, after the '
          "page's own cookie header", () async {
        final response = await client
            .withUnencryptedCookies({'a': 'x y', 'b': '2'})
            .get('/cookies', headers: {'cookie': 'c=3'});
        expect(response.jsonMap['cookies'], {'a': 'x y', 'b': '2', 'c': '3'});
      });

      test('withCookie encrypts as EncryptCookies expects', () async {
        final response = await client
            .withCookie('theme', 'dark')
            .get('/cookies');
        final sent = (response.jsonMap['cookies']! as Map)['theme'] as String;
        expect(sent, isNot('dark'));
        final clear = await app.run(() => Crypt.encrypter.decryptString(sent));
        expect(clear, endsWith('|dark'));
        expect(clear.length, 41 + 4);
      });

      test(
        'followingRedirects follows with GET to the last response',
        () async {
          (await client.get('/hop/1')).assertRedirect('/hop/2');
          final followed = await client.followingRedirects().get('/hop/1');
          followed.assertOk().assertJsonPath('query', 'x=1');
          (await client.followingRedirects().post('/form'))
              .assertOk()
              .assertJsonPath('query', '');
          await expectLater(
            client.followingRedirects().get('/loop'),
            throwsA(isA<TestFailure>()),
          );
        },
      );

      test('assertRedirect compares absolute URLs, as Laravel', () async {
        (await client.get('/hop/2'))
            .assertRedirect()
            .assertRedirect('/hop/3?x=1')
            .assertRedirect('http://localhost/hop/3?x=1')
            .assertRedirectContains('hop/3');
        expect(
          () => (TestResponse(
            status: 302,
            headers: Headers({'location': '/a'}),
            bodyBytes: const [],
            request: Request.fake(),
          )).assertRedirect('/b'),
          throwsA(isA<TestFailure>()),
        );
      });

      test('assertAuthenticated reads the guards the request asked', () async {
        (await client.withHeaders({'x-member': '7'}).get('/who'))
            .assertAuthenticated(guard: 'header')
            .assertAuthenticatedAs(Member()..setAttr('id', 7), guard: 'header');
        (await client.get('/who')).assertGuest(guard: 'header');
        final asked = await client.get('/nobody');
        asked.assertGuest(guard: 'header');
        expect(
          () => asked.assertAuthenticated(guard: 'header'),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message,
              'message',
              contains('was not asked'),
            ),
          ),
        );
        (await client
                .actingAs(Member()..setAttr('id', 3), guard: 'header')
                .get('/nobody'))
            .assertAuthenticatedAs(Member()..setAttr('id', 3), guard: 'header');
      });

      test('session assertions fail clearly without a session', () async {
        final response = await client.get('/nobody');
        expect(response.session, isNull);
        expect(
          () => response.assertSessionHas('x'),
          throwsA(
            isA<TestFailure>().having(
              (e) => e.message,
              'message',
              contains('No session'),
            ),
          ),
        );
      });
    });
  }

  test('CookieJar matches paths as RFC 6265', () {
    final jar = CookieJar()
      ..receive([
        'a=1; path=/',
        'b=2; path=/admin',
        'c=3',
        'd=4; Max-Age=0',
      ], Uri.parse('http://localhost/shop/cart'));
    expect(jar.pairsFor(Uri.parse('http://localhost/')), ['a=1']);
    expect(jar.pairsFor(Uri.parse('http://localhost/admin/x')), ['b=2', 'a=1']);
    expect(jar.pairsFor(Uri.parse('http://localhost/administrator')), ['a=1']);
    expect(jar.pairsFor(Uri.parse('http://localhost/shop/cart')), [
      'c=3',
      'a=1',
    ]);
    expect(jar['d'], isNull);
    jar
      ..put('e', 'x y')
      ..forget('a');
    expect(jar.all, {'b': '2', 'c': '3', 'e': 'x y'});
    jar.clear();
    expect(jar.all, isEmpty);
  });
}
