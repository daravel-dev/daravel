# Localization

Translations work as Laravel's: keyed lines with a fallback locale, JSON
lines keyed by the text itself, `:name` placeholders and plural lines, with
the active locale held per request, so concurrent requests in different
languages never see each other's.

## Lines

Keyed lines (Laravel's `lang/<locale>/*.php`) are registered in
`bootstrap/app.dart`; nested maps become dotted keys:

```dart
Application.configure(basePath: '.')
    .withTranslations({
      'en': {
        'auth': {'failed': 'These credentials do not match our records.'},
        'exam.welcome': 'Welcome, :name!',
        'exam.minutes': '{1} :count minute left|[2,*] :count minutes left',
      },
      'id': {
        'auth.failed': 'Kredensial ini tidak cocok dengan data kami.',
        'exam.welcome': 'Selamat datang, :name!',
        'exam.minutes': ':count menit tersisa',
      },
    })
```

JSON lines are read from `lang/<locale>.json` at boot, the same files a
Laravel application uses, so the two can share them:

```json
{"Log in": "Masuk", "Forgot your password?": "Lupa kata sandi?"}
```

Ship the `lang/` directory next to the binary, as `.env`.

## Translating

```dart
trans('exam.welcome', {'name': 'teo'});        // Welcome, teo!
trans('Log in');                               // Masuk (locale id)
transChoice('exam.minutes', 5);                // 5 minutes left
Lang.get('auth.failed', const {}, 'id');       // a given locale
Lang.has('exam.welcome');
```

`trans` is Laravel's `__()` and `trans()`: Dart keeps a leading underscore
for private names, so there is no `__`. A missing key returns the key.
`:name` takes the value as given, `:Name` capitalises it and `:NAME`
upper-cases it; the longest placeholder wins and replaced text is not
scanned again, as PHP's `strtr`.

`transChoice` (Laravel's `trans_choice`) fills `:count` and picks the form:
an explicit `{n}` or `[from,to]` segment (`*` for an open end) that matches,
otherwise the locale's plural form. The plural rules are Laravel's, for 280
locales, so `apple|apples` is `apples` for 0 in English, and Indonesian,
which has one form, always uses the first.

Keyed lines fall back to `APP_FALLBACK_LOCALE` (default `en`); JSON lines
do not, as in Laravel.

## The current locale

`APP_LOCALE` is the application locale. `App.setLocale('id')` changes it
for the rest of the current request, job or command, and `App.locale`
reads it. `SetLocaleMiddleware` picks it from `?lang=` or the
`Accept-Language` header among the locales you support:

```dart
.withMiddleware((middleware) {
  middleware.use(const [SetLocaleMiddleware(supported: ['en', 'id'])]);
})
```

Validation messages follow the current locale (English and Indonesian are
bundled).
