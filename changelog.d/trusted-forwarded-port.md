### Added

- `Request.port`: the port the client used, as Symfony's `Request::getPort()` reads it. From a trusted proxy's `X-Forwarded-Port`, else the port of its `X-Forwarded-Host`, else the port of `Host`, else the default of the scheme.

### Fixed

- `TrustProxiesMiddleware` listed `X-Forwarded-Port` but never applied it: behind a proxy that ends TLS on 443 in front of an application on another port, `url` kept that port (`https://app.test:8000/…`). The trusted port is now applied, and `url` writes a port only when it is not the scheme's default (#327).
- `Request.host` carried the port of a trusted `X-Forwarded-Host` (`example.com:8443`); it is now the host alone, as Symfony's `getHost()`, and the port goes to `Request.port`.
- `Request.url` wrote an IPv6 host without brackets (`http://::1:8080/…`); it now writes `http://[::1]:8080/…`.

### Upgrade notes

- Behind a trusted proxy, `url` (and with it the session's previous URL) can change: a port the proxy forwards in `X-Forwarded-Port` replaces the port of `Host`, and `host` no longer carries a port. Code that took the port out of `host` should read `port`.
