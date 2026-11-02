# Changelog

## 1.23.0

- Version aligned with Daravel 1.23.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.22.0

- Version aligned with Daravel 1.22.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.1

- Version aligned with Daravel 1.21.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.0

- Added: `SessionGuard` (`auth.session<User>('web', provider)`), Laravel's session guard on the same `login_web_<sha1>` key, so a login holds on both sides of a shared store. Remember-me cookies are not supported yet.

## 1.20.1

- Fixed: a JSON session (`'serialization' => 'json'`, the laravel/laravel 13 skeleton) read as empty and its row was replaced in PHP `serialize()` format, which logged the user out of Laravel. Both formats are read, also with `SESSION_ENCRYPT`, and a stored session keeps its format.
- Added: `SESSION_SERIALIZATION` (`php` or `json`), the format of new sessions; `json` by default with `COMPAT_LARAVEL_VERSION=13`.

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- Changed: the default `SESSION_DRIVER` is `database`, as laravel/laravel 11 to 13 (was `file`).
- Added `SESSION_ENCRYPT` (Laravel's `EncryptedStore` payload) and `SESSION_PARTITIONED_COOKIE`.

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- First release: `withSession()`, the `file`, `database` and `array` drivers on Laravel's `sessions` table and payload (`base64(serialize($attributes))`), `StartSessionMiddleware`, `EncryptCookiesMiddleware` (Laravel's `CookieValuePrefix` and `Crypt` payloads) and `VerifyCsrfTokenMiddleware` (`_token`, `X-CSRF-TOKEN`, `X-XSRF-TOKEN`, the `XSRF-TOKEN` cookie, 419 `CSRF token mismatch.`); `request.session`, `Session.current`, flash data, `regenerate`, `invalidate`; `CreateSessionsTable`.
