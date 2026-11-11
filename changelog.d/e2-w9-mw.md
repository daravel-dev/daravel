### Added

- `Mw` and `MiddlewareToken` (wave 9, W9.6): middleware aliases with the compiler's help, `Mw.auth(['token'])`, `Mw.can('update', ['post'])`, `Mw.throttle('login')`, `Mw.throttleLimit(maxAttempts: 60)`, `Mw.cacheHeaders(public: true, maxAge: 3600, etag: true)`, `Mw.feature([...])` and `Mw.signed`. Each token is exactly the alias string (`'can:update,post'`), so it resolves to the same middleware and mixes with strings in one list.

### Upgrade notes

- `package:daravel` (and `package:daravel/http.dart`) exports `Mw` and `MiddlewareToken` (from `src/http/middleware_tokens.dart`).
