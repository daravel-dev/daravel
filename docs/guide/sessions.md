# Sessions, cookies and CSRF

`daravel_session` gives web routes a session the way Laravel does: the
session id travels in an encrypted cookie, the attributes live in a file or
in Laravel's `sessions` table as PHP `serialize()` text or JSON, and
state-changing requests must carry the CSRF token. A Laravel application and a Daravel
application with the same `APP_KEY` and the same store share a visitor's
session, cookies and token.

```bash
dart pub add daravel_session
```

```dart
// bootstrap/app.dart
import 'package:daravel_session/daravel_session.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withSession()
    .withMigrations([...migrations, const CreateSessionsTable()])
    .withRouting(
      web: (Router router) => router.group((Router r) {
        r.get('/cart', (request) => request.session.get<List<Object?>>('cart'));
      }, middleware: const ['web']),
    )
    .create();
```

`withSession()` registers three middleware aliases and the `web` group that
runs them in Laravel's order:

| Alias | Middleware | Laravel |
| :-- | :-- | :-- |
| `encrypt_cookies` | `EncryptCookiesMiddleware` | `EncryptCookies` |
| `session` | `StartSessionMiddleware` | `StartSession` |
| `csrf` | `VerifyCsrfTokenMiddleware` | `VerifyCsrfToken` |

Put the group on the routes that need a session. API routes with bearer
tokens or JWTs do not need it, and do not pay for it.

## Settings

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `SESSION_DRIVER` | `database` | `database` (the `sessions` table, as laravel/laravel 11 to 13), `file` (`storage/framework/sessions`) or `array` (tests). 1.18 defaulted to `file`: set `SESSION_DRIVER=file` to keep it |
| `SESSION_LIFETIME` | `120` | Minutes a session may stay idle |
| `SESSION_EXPIRE_ON_CLOSE` | `false` | Session cookie without an expiry |
| `SESSION_COOKIE` | `<app name>_session` | Cookie name, `Str::slug(APP_NAME, '_')` as Laravel derives it (`my_app_session`) |
| `SESSION_TABLE`, `SESSION_CONNECTION` | `sessions`, default | The `database` driver's table and connection |
| `SESSION_PATH`, `SESSION_DOMAIN` | `/`, none | Cookie scope |
| `SESSION_SECURE_COOKIE`, `SESSION_HTTP_ONLY`, `SESSION_SAME_SITE` | `false`, `true`, `lax` | Cookie flags; `SESSION_SAME_SITE=none` needs the secure flag |
| `SESSION_ENCRYPT` | `false` | Store the payload encrypted with `Crypt`, as Laravel's `EncryptedStore` (`Crypt::encrypt(serialize($attributes))`) |
| `SESSION_PARTITIONED_COOKIE` | `false` | `Partitioned` (CHIPS) on the session and `XSRF-TOKEN` cookies, for an application embedded in another site |
| `SESSION_SERIALIZATION` | `php`, `json` with `COMPAT_LARAVEL_VERSION=13` | Format of new sessions, Laravel's `session.serialization` |

Both formats are always read, and a stored session is written back in the
format it has, so Daravel never logs anyone out of a Laravel application
that shares the store. `SESSION_SERIALIZATION` decides for sessions Daravel
creates, and Laravel must be able to read those: only the laravel/laravel 13
skeleton sets `'serialization' => 'json'`, so an application upgraded to 13
may still be on `php`. `dartisan adopt` reads the value from the Laravel
project's `config/session.php`.

With several isolates or servers use `database` (or the `file` driver on
one machine): the `array` driver is one isolate's memory. `CreateSessionsTable`
creates Laravel's table and does nothing when it exists already.

## The session

```dart
final session = request.session;      // or Session.current

session.put('cart.items', ['a']);     // dot keys nest, as in Laravel
session.push('cart.items', 'b');
session.get<String>('name', 'guest');
session.pull<int>('hits');
session.increment('views');
session.forget('name');
session.flush();

session.flash('status', 'Saved.');    // next request only
session.now('status', 'Saving...');   // this request only
session.reflash();
session.keep(['status']);

session.token;                        // the CSRF token
await session.regenerate();           // new id, new token, same data
await session.invalidate();           // flush + new id (logout)
session.previousUrl;                  // the last GET page
```

The attributes are written back after the response as `serialize()` text,
with Laravel's keys for the framework's own entries (`_token`, `_flash.old`,
`_flash.new`, `_previous.url`), so a Laravel application reading the same
file or row sees what it would have written. A PHP object Laravel stored
(a `ViewErrorBag`, for example) arrives as a `PhpObject` and is written
back unchanged.

## Cookies

`EncryptCookiesMiddleware` encrypts every cookie the response sets and
decrypts the ones the request carries, with `Crypt` and Laravel's value
prefix (`hmac_sha1(name . 'v2', key) . '|'`), so a cookie cannot be moved
to another name and a Laravel application reads the same cookies. A cookie
that fails to decrypt is dropped from the request. Cookies that must stay
readable by scripts or other systems go in `withSession(cookiesExcept:
['theme'])`.

## CSRF

`VerifyCsrfTokenMiddleware` lets `GET`, `HEAD` and `OPTIONS` through and
requires the session's token on anything else, from the `_token` input, the
`X-CSRF-TOKEN` header or the `X-XSRF-TOKEN` header. Every response sets the
`XSRF-TOKEN` cookie (encrypted, readable by scripts), which Axios and
Angular send back as `X-XSRF-TOKEN`. A missing or wrong token answers `419`
with `{"message": "CSRF token mismatch."}`, as Laravel does. Webhooks and
other endpoints called without a session skip the check with
`withSession(csrfExcept: ['webhooks/*'])`.

```html
<form method="post" action="/profile">
  <input type="hidden" name="_token" value="{{ request.session.token }}">
</form>
```

## Logging in

`SessionGuard` is Laravel's session guard. It keeps the user id under the
same `login_web_<sha1>` key, so a user logged in on either application is
logged in on both.

```dart
.withAuth((auth) => auth.session<User>('web', ModelUserProvider<User>(User.definition)))
```

```dart
final guard = App.make<AuthManager>().guard('web') as SessionGuard<User>;

await guard.attempt({'email': email, 'password': password}); // false on a mismatch
await guard.login(user);                                     // new session id and token
await guard.logout();
await request.session.invalidate();
```

`attempt(..., remember: true)` also writes Laravel's `remember_web_<sha1>`
cookie, which needs a nullable `remember_token` column and logs the user in
on either application once the session is gone; `logout` forgets it and
changes the token. `guard.viaRemember` tells whether this
request's user came from that cookie.

Put `auth:web` after the `web` group on protected routes. From
`COMPAT_LARAVEL_VERSION=12` the login also stores `password_hash_web`, which
Laravel's `AuthenticateSession` compares.

## Not covered

The `cookie` session driver, `ViewErrorBag` (`back()->withErrors()`),
and session blocking (`Route::block`). Laravel's `sessions` table and cookie formats are the contract; the
rest is Daravel's own API.
