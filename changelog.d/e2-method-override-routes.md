### Added

- `Request.bodyBytesRead`, `Request.enforceLimitOnBodyRead()` and `Request.abortBodyRead(error)`. `MethodOverrideMiddleware(router:, defaultTimeout:)`.

### Changed

- `MethodOverrideMiddleware` reads a form body (urlencoded or multipart) for its `_method` only where the request's path has a `PUT`, `PATCH` or `DELETE` route, and then under the loosest body limit and timeout of the routes it may reach (that path's `POST` route and those), a timeout answering `503`. Before, it parsed every form `POST` before routing, whatever its path, under the global limit only, multipart files written to disk included (since 1.22.0). The kernel now checks the matched route's `bodyLimit` against whatever was read before routing, by any global middleware: a form within the global limit but over the route's was accepted when the handler read it parsed (`all()`, `validate`). The header (`X-HTTP-Method-Override`) still comes first and reads no body; a `_method` in the query still applies everywhere. `BodyLimitsMiddleware` on a route group also refuses a body already read over its limit (a chunked one declares no length).

### Upgrade notes

- Upgrading can change which route a form reaches: a `_method` in the body of a path that has only a `POST` route stays `POST` (Laravel answers 405), and a form over a route's `bodyLimit` is refused with `413` although its handler reads it parsed. A form `POST` to a path with `PUT`, `PATCH` or `DELETE` routes is parsed within the largest limit and timeout of that path's routes, so a slow upload there gets a `503` after the largest timeout.
