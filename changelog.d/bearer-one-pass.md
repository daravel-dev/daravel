### Fixed

- Security: the token of an `Authorization: Bearer` header is read in one pass. The regular expression used before took time quadratic in a run of white space inside the token, and the token guard (`TokenGuard`) and the JWT guard (`JwtGuard`) ran it on every request before looking anything up, without a valid token; `bearerTokenOf` gives the same results as before. Since 1.0.0; the default header limits (`HTTP_MAX_HEADER_LINE_BYTES`, 16 KiB per line) kept it to about 2 s per request, but without them one request held an isolate for seconds to minutes. Until you upgrade, keep those limits, or limit the size of a header line at the proxy in front of the application (for example 8 KiB).
- Security: a `Host` (or absolute-form authority, or trusted `X-Forwarded-Host`) whose host is longer than 253 characters, which no DNS name is, is refused with 400 (a forwarded value is ignored). Domain routes with two parameters in one label took time quadratic in the length of the host.

### Upgrade notes

- A request whose host is longer than 253 characters is answered 400 before it reaches the application.
