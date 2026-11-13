### Added

- `HTTP_MAX_JSON_BODY` and `HTTP_MAX_FORM_BODY` (bytes, 1 MiB each; `0` for none of their own): the engine's limit for JSON (`application/json`, `+json`) and `application/x-www-form-urlencoded` bodies, applied to every request, from a socket and from the test client alike, and never above `HTTP_MAX_BODY`; a body over it is refused with Laravel's `413` body when it is read (`HttpKernel.jsonBodyLimit`, `formBodyLimit`, `BodyLimits`). A route's `bodyLimit` and `BodyLimitsMiddleware` replace it. `dartisan doctor` shows the limits of each body type and warns when either is `0` in production without `BodyLimitsMiddleware`. Guide: [Configuration](docs/guide/configuration.md).

### Upgrade notes

- Upgrading can change what an application accepts: without `BodyLimitsMiddleware`, a JSON or form body above 1 MiB, accepted up to `HTTP_MAX_BODY` (50 MiB) before, is now refused with `413` when the application reads it. Raise the limit with `HTTP_MAX_JSON_BODY` / `HTTP_MAX_FORM_BODY`, for one route with `.bodyLimit(bytes)`, or set `0` to read them up to `HTTP_MAX_BODY` as before (one large body then makes a worker parse and validate all of it). Applications that use `BodyLimitsMiddleware` keep its limits. New public name `BodyLimits` in `package:daravel` (an application class of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
