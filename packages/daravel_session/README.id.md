<!-- source: README.md sha256:55bf4c309bc9 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_session

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_session/README.md) · Bahasa Indonesia

Session yang kompatibel dengan Laravel untuk [Daravel](https://pub.dev/packages/daravel):
id session di dalam cookie terenkripsi, atribut di file atau di tabel
`sessions` Laravel sebagai teks PHP `serialize()`, dan proteksi CSRF.
Aplikasi Laravel dan aplikasi Daravel dengan `APP_KEY` dan penyimpanan yang
sama berbagi session, cookie, dan token seorang pengunjung.

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

`withSession()` mendaftarkan middleware `encrypt_cookies`, `session`, dan
`csrf` serta grup `web` yang menjalankannya dalam urutan Laravel
(`EncryptCookies`, `StartSession`, `VerifyCsrfToken`).

```dart
final session = request.session;   // atau Session.current
session.put('cart.items', ['a']);
session.flash('status', 'Saved.');
session.token;                     // token CSRF
await session.regenerate();
await session.invalidate();        // logout
```

- `SESSION_DRIVER=file|database|array`, `SESSION_LIFETIME=120`,
  `SESSION_COOKIE` (`<nama app>_session`), `SESSION_SECURE_COOKIE`,
  `SESSION_SAME_SITE=lax`, seperti `config/session.php` Laravel.
- Cookie dienkripsi dengan `Crypt` dan prefix nilai Laravel; cookie yang
  gagal didekripsi dibuang.
- `POST`, `PUT`, `PATCH`, dan `DELETE` butuh token (`_token`, `X-CSRF-TOKEN`,
  atau `X-XSRF-TOKEN`); cookie `XSRF-TOKEN` di-set pada setiap respons;
  ketidakcocokan dijawab `419 CSRF token mismatch.`

Panduan: [Session, cookie, dan CSRF](https://daravel.dev/id/sessions.html).
Belum tercakup: driver `cookie`, `ViewErrorBag`, session blocking, dan
cookie remember-me.
