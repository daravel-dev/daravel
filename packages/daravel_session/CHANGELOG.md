# Changelog

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- First release: `withSession()`, the `file`, `database` and `array` drivers on Laravel's `sessions` table and payload (`base64(serialize($attributes))`), `StartSessionMiddleware`, `EncryptCookiesMiddleware` (Laravel's `CookieValuePrefix` and `Crypt` payloads) and `VerifyCsrfTokenMiddleware` (`_token`, `X-CSRF-TOKEN`, `X-XSRF-TOKEN`, the `XSRF-TOKEN` cookie, 419 `CSRF token mismatch.`); `request.session`, `Session.current`, flash data, `regenerate`, `invalidate`; `CreateSessionsTable`.
