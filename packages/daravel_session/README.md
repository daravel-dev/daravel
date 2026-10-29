<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_session

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_session/README.id.md)

Laravel-compatible sessions for [Daravel](https://pub.dev/packages/daravel):
the session id in an encrypted cookie, the attributes in a file or in
Laravel's `sessions` table as PHP `serialize()` text, and CSRF protection.
A Laravel application and a Daravel application with the same `APP_KEY` and
store share a visitor's session, cookies and token.

```bash
dart pub add daravel_session
```

```dart
// bootstrap/app.dart
import 'package:daravel_session/daravel_session.dart';

Application createApp() => Application.configure(basePath: '.')
    .withSession()
    .withMigrations([...migrations, const CreateSessionsTable()])
    .withRouting(
      web: (Router router) => router.group((Router r) {
        r.get('/cart', (request) => request.session.get<List<Object?>>('cart'));
      }, middleware: const ['web']),
    )
    .create();
```

`withSession()` registers the `encrypt_cookies`, `session` and `csrf`
middleware and the `web` group that runs them in Laravel's order
(`EncryptCookies`, `StartSession`, `VerifyCsrfToken`).

```dart
final session = request.session;   // or Session.current
session.put('cart.items', ['a']);
session.flash('status', 'Saved.');
session.token;                     // the CSRF token
await session.regenerate();
await session.invalidate();        // logout
```

- `SESSION_DRIVER=database|file|array` (default `database`), `SESSION_LIFETIME=120`,
  `SESSION_COOKIE` (`<app name>_session`), `SESSION_SECURE_COOKIE`,
  `SESSION_SAME_SITE=lax`, as Laravel's `config/session.php`.
- Cookies are encrypted with `Crypt` and Laravel's value prefix; a cookie
  that fails to decrypt is dropped.
- `POST`, `PUT`, `PATCH` and `DELETE` need the token (`_token`,
  `X-CSRF-TOKEN` or `X-XSRF-TOKEN`); the `XSRF-TOKEN` cookie is set on every
  response; a mismatch is `419 CSRF token mismatch.`

Guide: [Sessions, cookies and CSRF](https://daravel.dev/sessions.html).
Not covered: the `cookie` driver, `ViewErrorBag`, session blocking and
remember-me cookies.
