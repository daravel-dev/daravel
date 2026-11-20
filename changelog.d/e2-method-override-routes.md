### Added

- `Request.bodyBytesRead` and `Request.enforceLimitOnBodyRead()`.

### Changed

- `MethodOverrideMiddleware` parses a form body on a path with a `PUT`, `PATCH` or `DELETE` route under the loosest `bodyLimit` of the routes it may reach (that path's `POST` route and those). The kernel now checks the matched route's `bodyLimit` against whatever was read before routing, by any global middleware: a form within the global limit but over the route's was accepted when the handler read it parsed (`all()`, `validate`). `BodyLimitsMiddleware` on a route group also refuses a body already read over its limit (a chunked one declares no length).

### Upgrade notes

- Upgrading can change which forms are accepted: a form over a matched route's `bodyLimit` is now refused with `413` although its handler reads it parsed, and a form `POST` to a path with `PUT`, `PATCH` or `DELETE` routes is parsed within the largest `bodyLimit` of that path's routes.
