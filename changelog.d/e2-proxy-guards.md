### Fixed

- `withUpstream` with `preserveHost`: a client's `Connection: host` no longer drops its `Host` (the upstream got its own host while `x-forwarded-host` stayed the client's), and an `X-Forwarded-For` that `Connection` names is not passed on as the chain. The upstream request is aborted on any failure before its answer, not only a timeout or a network error.
- Shadow parity (`withUpstream(shadowSampleRate:)`): `except` paths are matched as the router matches them, whole segments: `//secret` is excluded by `except: ['/secret']` (it reached the `/secret` route and was replayed), and `/secret_public` no longer is.
- `CorsMiddleware` adds `Origin` to the response's `Vary` instead of replacing it (a handler's `Vary: Accept-Encoding` was lost), as Laravel's `HandleCors` does.
