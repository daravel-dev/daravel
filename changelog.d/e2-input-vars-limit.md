### Fixed

- Bound the number of query and URL-encoded form pairs before building nested input. A form body is counted on its bytes, before it is decoded, and the query once per request.

### Upgrade notes

- Query strings and URL-encoded forms with more than 1,000 nonempty pairs now return 400 when read instead of accepting all input. Set `HTTP_MAX_INPUT_VARS` to a limit appropriate for the application, or `0` for none (a negative value is an error at boot); PHP instead warns and truncates excess input. Multipart retains its separate part limit.
- New: `Request.maxInputVars` (`int?`, `null` for no limit), `Request.defaultMaxInputVars`, `Request.maxInputVarsFromEnv`, `HttpKernel.maxInputVars`, and an optional `maxInputVars` on `parseQueryString`, which sets no limit unless given (a query string an application builds or parses itself is not limited).
