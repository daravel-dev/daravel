### Fixed

- Security: the request's URI, `scheme`, `host`, `url` and `isSecure` came from `dart:io`'s `HttpRequest.requestedUri`, which reads `X-Forwarded-Proto` and `X-Forwarded-Host` from any client, also without `TrustProxiesMiddleware` and from a peer it does not trust. They now come from the request line, the `Host` header and the listener; forwarded values count only when `TrustProxiesMiddleware` trusts the peer, as in Laravel (Symfony's `Request::getHost()` and `isSecure()` read them only from a trusted proxy). A `Host` header (or the authority of an absolute-form request target) that is not a host and an optional port is now refused with 400, as Symfony refuses it: before, characters such as `/`, `?`, `#` or `@` in it changed the path or host the application saw. The path and query always come from the request line. This also covers domain routes, the host of signed URLs on domain routes, `Response.back`, the session's previous URL, the HSTS header and `UpstreamProxy`. Since 1.0.0.

### Added

- `Request.isFromTrustedProxy` (Laravel's `isFromTrustedProxy()`): whether `TrustProxiesMiddleware` applied a trusted proxy's forwarding headers.
- The server logs one warning when a request carries `X-Forwarded-Proto` or `X-Forwarded-Host` that no trusted proxy applied. It is said once per isolate and carries no header value.
- `dartisan doctor`, in production with an `https` `APP_URL`: a notice that the server speaks plain HTTP and requests see `https` and the public host only from a proxy `TrustProxiesMiddleware` trusts.

### Upgrade notes

- **Upgrading can change what an application sees behind a proxy.** Without `TrustProxiesMiddleware`, an application behind a proxy that sends `X-Forwarded-Proto`/`X-Forwarded-Host` used to see the client's scheme and host from those headers; it now sees `http` and the `Host` the proxy connects with (which may be an internal host and port), and `isSecure` is false, until it trusts the proxy: `middleware.use([TrustProxiesMiddleware(proxies: ['10.0.0.0/8']), ...])` (the starter has this line as a comment, and the deployment guide shows it). URLs built from `APP_URL` (`route()`, signed URLs, mail, storage) are not affected.
- A request whose `Host` is not a host and an optional port (letters, digits, `-`, `_` and dots, an IPv4 address or a bracketed IPv6 address; a raw IDN included) is now answered 400 before it reaches the application, as Symfony refuses it.
