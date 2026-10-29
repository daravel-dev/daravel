# Sessions, cookies and CSRF

`daravel_session` gives web routes a session the way Laravel does: the
session id travels in an encrypted cookie, the attributes live in a file or
in Laravel's `sessions` table as PHP `serialize()` text, and state-changing
requests must carry the CSRF token. A Laravel application and a Daravel
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
| `SESSION_DRIVER` | `file` | `file` (`storage/framework/sessions`), `database` (the `sessions` table) or `array` (tests) |
| `SESSION_LIFETIME` | `120` | Minutes a session may stay idle |
| `SESSION_EXPIRE_ON_CLOSE` | `false` | Session cookie without an expiry |
| `SESSION_COOKIE` | `<app name>_session` | Cookie name, `Str::slug(APP_NAME, '_')` as Laravel derives it (`my_app_session`) |
| `SESSION_TABLE`, `SESSION_CONNECTION` | `sessions`, default | The `database` driver's table and connection |
| `SESSION_PATH`, `SESSION_DOMAIN` | `/`, none | Cookie scope |
| `SESSION_SECURE_COOKIE`, `SESSION_HTTP_ONLY`, `SESSION_SAME_SITE` | `false`, `true`, `lax` | Cookie flags; `SESSION_SAME_SITE=none` needs the secure flag |

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

## Not covered

The `cookie` session driver, `ViewErrorBag` (`back()->withErrors()`),
session blocking (`Route::block`) and remember-me cookies of the `web`
guard. Laravel's `sessions` table and cookie formats are the contract; the
rest is Daravel's own API.
