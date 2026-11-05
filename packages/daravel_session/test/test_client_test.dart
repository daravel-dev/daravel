import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// `TestClient.browser()`, `withSession`, `withCookie` and the session and
/// authentication assertions against the real `web` group: encrypted
/// cookies, the session and CSRF, as a browser meets them.

const String appKey = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password'],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  String get name => getAttr('name');
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
    table.string('remember_token').nullable();
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

String escape(Object? value) => const HtmlEscape().convert('${value ?? ''}');

void main() {
  late Directory base;
  late Application app;
  late User ana;

  Application build() => Application.configure(basePath: base.path)
      .withEnv({
        'APP_ENV': 'testing',
        'APP_NAME': 'My App',
        'APP_KEY': appKey,
        'DB_DATABASE': ':memory:',
        'SESSION_DRIVER': 'array',
      })
      .withLogLevel(LogLevel.critical)
      .withSession(cookiesExcept: const ['plain'])
      .withMigrations(const [CreateUsers()])
      .withAuth(
        (auth) =>
            auth.session<User>('web', ModelUserProvider<User>(User.definition)),
      )
      .withRouting(
        web: (router) => router.group((r) {
          StatefulGuard<User> guard() =>
              Auth.guard('web') as StatefulGuard<User>;
          r.get('/login', (request) {
            final session = request.session;
            final errors = session.errors['email'];
            return Response.html(
              '<form method="post" action="/login">'
              '<input type="hidden" name="_token" '
              'value="${session.token}">'
              '<input name="email" value="${escape(session.old<String>('email'))}">'
              '${errors is List ? '<p>${escape(errors.first)}</p>' : ''}'
              '<button>Log in</button></form>',
            );
          });
          r.post('/login', (request) async {
            final data = await request.validate({
              'email': 'required|email',
              'password': 'required',
            });
            if (!await guard().attempt({
              'email': data.get('email'),
              'password': data.get('password'),
            })) {
              throw ValidationException({
                'email': ['These credentials do not match our records.'],
              });
            }
            await request.session.regenerate();
            return Response.redirect('/dashboard');
          });
          r
              .get('/dashboard', (request) async {
                final user = (await guard().user())!;
                return Response.html('<h1>Hello ${escape(user.name)}</h1>');
              })
              .middleware(['auth:web']);
          r.post('/logout', (request) async {
            await guard().logout();
            await request.session.invalidate();
            request.session.regenerateToken();
            return Response.redirect('/login');
          });
          r.get(
            '/session',
            (request) => {
              'cart': request.session.get<Object>('cart'),
              'visits': request.session.increment('visits'),
            },
          );
          r.post('/forget-cart', (request) {
            request.session
              ..forget('cart')
              ..flash('status', 'Cart emptied');
            return Response.redirect('/session');
          });
          r.get(
            '/cookies',
            (request) => {
              'theme': request.cookie('theme'),
              'plain': request.cookie('plain'),
            },
          );
        }, middleware: const ['web']),
      )
      .create();

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_session_client');
    app = build();
    await app.boot();
    ana = await app.run(() async {
      await App.make<Migrator>().run();
      return User.definition.query().create({
        'name': 'Ana',
        'email': 'ana@x.io',
        'password': await Hash.make('secret'),
      });
    });
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  for (final transport in TestTransport.values) {
    group('${transport.name}:', () {
      TestClient client() => TestClient(app, transport: transport);

      test('a web login: form, wrong password, login, page, logout', () async {
        final browser = client().browser();

        (await browser.get('/login'))
            .assertOk()
            .assertSee('name="_token"')
            .assertCookie('my_app_session')
            .assertCookie('XSRF-TOKEN')
            .assertGuest(guard: 'web');

        // A failed attempt goes back to the form with the errors and the
        // input flashed, as Laravel's Handler::invalid() does.
        (await browser.post(
              '/login',
              form: {'email': 'ana@x.io', 'password': 'wrong'},
            ))
            .assertRedirect('/login')
            .assertSessionHasErrors(['email'])
            .assertSessionHasErrors({
              'email': 'These credentials do not match our records.',
            })
            .assertSessionDoesntHaveErrors(['password'])
            .assertSessionHasInput('email', 'ana@x.io')
            .assertGuest(guard: 'web');
        (await browser.get('/login'))
            .assertSee('These credentials do not match our records.')
            .assertSee('value="ana@x.io"');
        // Flash data lasts one request.
        (await browser.get('/login'))
            .assertSessionHasNoErrors()
            .assertDontSee('These credentials');

        (await browser.post(
              '/login',
              form: {'email': 'ana@x.io', 'password': 'secret'},
            ))
            .assertRedirect('/dashboard')
            .assertSessionHasNoErrors()
            .assertAuthenticated(guard: 'web')
            .assertAuthenticatedAs(ana, guard: 'web');

        (await browser.get('/dashboard'))
            .assertOk()
            .assertSee('Hello Ana')
            .assertAuthenticatedAs(ana, guard: 'web');

        (await browser.followingRedirects().post('/logout'))
            .assertOk()
            .assertSee('Log in')
            .assertGuest(guard: 'web');
        (await browser.get('/dashboard')).assertUnauthorized();
      });

      test('followingRedirects keeps the cookies of every hop', () async {
        final browser = client().browser().followingRedirects();
        await browser.get('/login');
        (await browser.post(
          '/login',
          form: {'email': 'ana@x.io', 'password': 'secret'},
        )).assertOk().assertSee('Hello Ana');
      });

      test('CSRF: the X-XSRF-TOKEN of a browser and the form _token pass, '
          'a missing token is a 419', () async {
        // Without a cookie jar there is no session to check against.
        (await client().post('/forget-cart')).assertStatus(419);

        final noXsrf = client().browser(xsrf: false);
        final form = await noXsrf.get('/login');
        (await noXsrf.post('/forget-cart')).assertStatus(419);
        final token = RegExp(r'name="_token" value="([^"]+)"')
            .firstMatch(form.body)!
            .group(1)!;
        (await noXsrf.post('/forget-cart', form: {'_token': token}))
            .assertRedirect('/session')
            .assertSessionHas('status', 'Cart emptied');

        final browser = client().browser();
        await browser.get('/login');
        (await browser.post('/forget-cart')).assertRedirect('/session');
        // A browser that has not been anywhere has no XSRF-TOKEN yet.
        (await client().browser().post('/forget-cart')).assertStatus(419);
      });

      test('withSession seeds the session; a browser keeps it in the '
          'cookie', () async {
        // A plain client: every request starts a new session, seeded again.
        final seeded = client().withSession({
          'cart': ['apple'],
        });
        (await seeded.get('/session'))
            .assertJsonPath('cart', ['apple'])
            .assertSessionHas('cart')
            .assertSessionHas('cart', ['apple'])
            .assertSessionHas('cart', contains('apple'))
            .assertSessionHas('cart', (Object? cart) => cart is List)
            .assertSessionHasAll({
              'cart': ['apple'],
              'visits': 1,
            })
            .assertSessionMissing('status')
            .assertSessionMissing('cart', ['pear']);
        (await seeded.get('/session')).assertJsonPath('visits', 1);

        // A browser: seeded once, then the session lives on.
        final browser = client().browser().withSession({
          'cart': ['apple'],
        });
        (await browser.get('/session')).assertJsonPath('visits', 1);
        (await browser.get('/session'))
            .assertJsonPath('visits', 2)
            .assertJsonPath('cart', ['apple']);
        (await browser.post('/forget-cart'))
            .assertSessionMissing('cart')
            .assertSessionHas('status', 'Cart emptied');
        (await browser.get('/session')).assertJsonPath('cart', null);
        expect(
          () => TestResponse(
            status: 200,
            headers: Headers(),
            bodyBytes: const [],
            request: Request.fake(),
          ).assertSessionHas('cart'),
          throwsA(isA<TestFailure>()),
        );
      });

      test('withCookie is encrypted for EncryptCookies, '
          'withUnencryptedCookie is not', () async {
        (await client()
                .withCookie('theme', 'dark')
                .withUnencryptedCookie('plain', 'yes')
                .get('/cookies'))
            .assertJsonPath('theme', 'dark')
            .assertJsonPath('plain', 'yes');
        // An unencrypted cookie EncryptCookies does not skip is dropped.
        (await client().withUnencryptedCookie('theme', 'dark').get('/cookies'))
            .assertJsonPath('theme', null);
      });
    });
  }
}
