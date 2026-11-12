# Testing

`package:daravel_test` drives your application without opening sockets:

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#testing -->
```dart
(await client.get('/api/posts'))
    .assertOk()
    .assertJsonPath('data.0.title', 'Hello')
    .assertJsonPath('meta.total', 1);

(await client.post(
  '/api/posts',
  json: {'title': 'x'},
)).assertUnauthorized().assertJsonPath('message', 'Unauthenticated.');

(await client.get('/api/posts/99')).assertNotFound();
```
<!-- /include -->

- `TestClient(app)` with `actingAs(user)`, `withToken(token)`, `browser()`,
  `withSession`, `withCookie`, `followingRedirects()`,
  `withHeaders`, `withoutExceptionHandling()`.
- `TestResponse` assertions: status helpers, `assertJson`,
  `assertExactJson`, `assertJsonPath`, `assertJsonStructure`,
  `assertJsonValidationErrors`, headers, cookies, `assertRedirect`, the
  session (`assertSessionHas`, `assertSessionHasErrors`) and the guards
  (`assertAuthenticated`, `assertGuest`).
- `refreshDatabase(() => createApp(...))` runs each test in a transaction
  that is rolled back (Laravel's `RefreshDatabase`); `assertDatabaseHas` /
  `assertDatabaseMissing` / `assertDatabaseCount`.
- Fakes: `Event.fake()`, `Queue.fake()`, `Storage.fake()`, with
  `assertDispatched`, `assertPushed`, ...
- Time: `freezeTime()`, `travel(duration)`, `travelTo(time)`; domain time
  reads `Clock.now()`.
- Architecture: `expectRegistryComplete()` and lints via `dartisan lint`.
- Form requests: `expectFormRequestTyped(form, sampleInput, read: (input)
  => input.typed)` validates a sample and reads every field as its declared
  type, so a `Field<int>` whose rules let a string through fails here, not
  as a 500 in production ([Validation](validation.md#typed-input)).
  `make:request` writes one such test.

Run the suite with `dartisan test` (`--coverage` writes `coverage/`).

### A test application

`bootTestApp(createApp)` creates the application with the test environment
and boots it. `createApp` is the one in `bootstrap/app.dart`, of type
`TestAppFactory`. The environment is `testEnv()`:

- `APP_ENV=testing`
- `DB_CONNECTION=sqlite`
- `DB_URL=sqlite::memory:`, a fresh database per application

The base path is the current directory, which `dart test` sets to the
package root. Before:

```dart
setUp(() async {
  app = createApp(
    basePath: Directory.current.path,
    env: <String, String>{
      'APP_ENV': 'testing',
      'APP_NAME': 'Starter',
      'DB_CONNECTION': 'sqlite',
      'DB_URL': 'sqlite::memory:',
    },
  );
  await app.boot();
  client = TestClient(app);
});
tearDown(() => app.shutdown());
```

After:

```dart
setUp(() async {
  app = await bootTestApp(createApp, env: {'APP_NAME': 'Starter'});
  client = TestClient(app);
});
tearDown(() => app.shutdown());
```

`env` values are applied after the test environment, so they can replace
it. Shutting the application down stays in the test, next to where it
starts. With `refreshDatabase`, pass `testEnv()` yourself:
`refreshDatabase(() => createApp(basePath: Directory.current.path, env:
testEnv()))`.

## Web routes: cookies, session and CSRF

Laravel's tests keep the session in memory between requests and skip CSRF.
Daravel reads the session from its cookie on every request and checks CSRF
in tests too, so a test of `web` routes behaves like a browser:
`client.browser()` keeps the cookies the application sets in a `CookieJar`
and sends them back, asks for HTML, and sends the `XSRF-TOKEN` cookie back
as the `X-XSRF-TOKEN` header on `POST`, `PUT`, `PATCH` and `DELETE`, as
Axios does, so `VerifyCsrfToken` accepts the request:

```dart
final browser = TestClient(app).browser();

(await browser.get('/login')).assertOk().assertCookie('XSRF-TOKEN');

(await browser.post('/login', form: {'email': 'ana@x.io', 'password': 'wrong'}))
    .assertRedirect('/login')
    .assertSessionHasErrors(['email'])
    .assertSessionHasInput('email', 'ana@x.io')
    .assertGuest(guard: 'web');

(await browser.post('/login', form: {'email': 'ana@x.io', 'password': 'secret'}))
    .assertRedirect('/dashboard')
    .assertAuthenticatedAs(ana, guard: 'web');

(await browser.followingRedirects().post('/logout')).assertOk().assertGuest();
```

- `browser(xsrf: false)` adds no header, to test the `419` of a missing
  token; a form that posts its `_token` field still passes.
- `followingRedirects()` follows redirects with `GET` and returns the last
  response, keeping the cookies of every hop.
- `withSession({'cart': [...]})` puts data into the session the `web`
  group starts. A browser client seeds its next request only, and the
  session then lives on in the cookie; any other client seeds every request.
- `withCookie(name, value)` / `withCookies` send cookies encrypted as
  `EncryptCookies` expects (Laravel's `CookieValuePrefix` with the
  application key); `withUnencryptedCookie` / `withUnencryptedCookies` send
  them as they are.
- On the response: `assertSessionHas(key, [value])` (a value, a `Matcher`
  or a `bool Function(Object?)`), `assertSessionHasAll`,
  `assertSessionMissing`, `assertSessionHasInput`, `assertSessionHasErrors`
  (a field, a list, or a map of field to message),
  `assertSessionDoesntHaveErrors`, `assertSessionHasNoErrors`;
  `assertCookie`, `assertPlainCookie`, `assertCookieExpired`,
  `assertCookieNotExpired`, `assertCookieMissing`; `assertRedirect('/path')`
  (a path and the absolute URL of the same page match) and
  `assertRedirectContains`.
- `assertAuthenticated(guard:)`, `assertGuest(guard:)` and
  `assertAuthenticatedAs(user, guard:)` read the user each guard had when
  the request ended. Laravel's guard outlives the request; here a guard
  nothing asked during the request (no `auth` middleware, no `Auth.user()`,
  no login) counts as a guest, and `assertAuthenticated` says so: assert on
  the login response or on a page behind `auth`.

The session assertions need `daravel_session`'s `web` group on the route;
`daravel_test` reads the session through the core `SessionStore` interface
and does not depend on that package. All of this works over the socket
transport too.

## In process or over a socket

`TestClient` calls `Application.handle` directly: fast, and enough for most
tests. What `dart:io` itself does to a response (default headers, `HEAD`,
`Content-Length`, compression) only shows on a real socket, so the same
tests can run through a real `ServerEngine` on a loopback port:

```bash
DARAVEL_TEST_TRANSPORT=socket dart test      # every TestClient in the suite
```

```dart
final client = TestClient(app, transport: TestTransport.socket);  // one client
```

The application sees the same request either way (host `localhost`, the
same JSON, form and multipart bytes), `actingAs`, `withSession` and the
session and guard assertions still work, redirects are followed only with
`followingRedirects()` and gzip bodies are not unpacked. Two things stay in process:
`withoutExceptionHandling()` (an exception cannot cross a socket) and
headers `HttpClient` cannot send (non-ASCII values, as in fuzzing). Under
`refreshDatabase` the server runs inside the test's transaction. Running
the suite both ways in CI catches what in-process tests cannot see.

## In a browser (Playwright)

`TestClient` tests the application from inside. An end-to-end suite tests
it from outside, as a browser and an HTTP client see it: the page renders
without console errors, the headers arrive, a token issued at login opens
`/api/auth/me` until logout, the sixth login in a minute answers 429.
Daravel uses [Playwright](https://playwright.dev) (Laravel has Dusk), which
needs Node.js 20+:

```bash
dartisan e2e:install            # tests/e2e: config and specs
cd tests/e2e && npm install && npx playwright install chromium
dartisan test:e2e --serve       # starts the app on a fresh database, runs the suite
```

`--serve` runs `migrate:fresh --seed` on `database/e2e.sqlite` and `serve`
on port 8000 (`--port`), and reuses a server already running there. It
always uses that SQLite file (`E2E_DATABASE` names another one), never the
database in `.env`, so it cannot wipe tables shared with Laravel; a project
whose migrations need PostgreSQL or MySQL tests a running server with
`--url`. Against another server, a DDEV site or staging: `dartisan test:e2e
--url=https://shop.ddev.site` (local TLS certificates are accepted).
`--api` runs only the `*.api.spec.ts` specs, over HTTP without a browser;
`--ui` opens Playwright's UI mode; what follows `--` goes to Playwright
(`dartisan test:e2e -- -g login`). `dartisan make:e2e Checkout` adds
`specs/web/checkout.spec.ts`, and `--api` an API spec.

The specs share one server, so they run on one worker: its database and
its rate limits (five registrations a minute per IP in new projects) are
the real ones. The starter's suite runs in CI on every commit.

## Conformance tests

`package:daravel_test/conformance.dart` exposes Laravel 12's wire contracts
as matchers, so an application can prove it still speaks Laravel:

```dart
import 'package:daravel_test/conformance.dart';

expect(response.json, isLaravelValidationError({'email': ['The email field is required.']}));
expect(response.json, isLaravelErrorBody(LaravelContract.unauthenticated));
expect(token, matches(LaravelContract.sanctumPlainTextToken));
expect(body, isLaravelLengthAwarePaginator());
```

New projects include `test/conformance/` and `dart_test.yaml`; run them with
`dartisan test --conformance`.

## Laravel equivalents

More of Laravel that this works with, and the API to look up on pub.dev.

| Laravel | Daravel | API | Note |
| :-- | :-- | :-- | :-- |
| `$this->actingAs($user)` | `client.actingAs(user)` | `TestClient.actingAs` |  |
| `->assertOk() / assertCreated() / assertUnprocessable()` | `.assertOk() / .assertCreated() / .assertUnprocessable()` | `TestResponse.assertUnprocessable` |  |
