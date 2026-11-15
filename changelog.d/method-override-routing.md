### Changed
- Form method overrides read a body only on paths with a matching PUT, PATCH, or DELETE route, within the longest request timeout of the routes that path may reach.

### Upgrade notes
- A POST-only path keeps its POST method when `_method` is supplied in the form body. Header and query overrides still apply. Register the target PUT, PATCH, or DELETE route on that path to use a body override. Body size defaults remain unchanged.
- `MethodOverrideMiddleware` accepts optional `router` and `defaultTimeout` callbacks. `Request.abortBodyRead` ends an active body read, and `Request.bodyRefusedWhileReading` indicates that the response closes its connection.
