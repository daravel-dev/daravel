### Added

- `Loggable` (`toLogValue()`): a value the logger turns into plain data before redacting it; `Headers` implements it.

### Fixed

- Security: `/up/ready` answered anyone with the raw text of a failing check, also without `APP_DEBUG` (a connection URL with its password, an internal host). Without `APP_DEBUG` the body now holds each check's name, `ok`, time and the meta its author chose to show (`HealthResult.ok({...})`), without the error, which goes to the log, at most once a second per worker. Since 1.0.0.
- Security: log redaction looked only into `Map<String, …>` and `List` values: a `Map<dynamic, dynamic>`, a `Map<Object?, Object?>`, a `Set` or a `Headers` object in the log context was written as it was, `authorization` and `cookie` included. Every map (keys written with `toString`), iterable and `Headers` is now redacted, keys match whatever their case and `-`/`_` (`X-Api-Key` matches `api_key`), and the default keys add `passwd`, `pwd`, `bearer`, `apikey`, `jwt`, `session_id`, `private_key`, `credentials` and `dsn`. Redaction never throws and always ends: a value whose iteration, `toLogValue()` or key `toString()` throws is written as `[UNLOGGABLE: <type>]`, and past 10 000 values per record (an endless iterable, a structure holding itself twice) the rest is `[TRUNCATED]`. Since 1.0.0.
- The console log handler wrote a message's and an error's control characters as they were: a `\r\n` carried in a route parameter or a header forged a log line, and an ESC reached the terminal. C0 (tab kept), DEL and C1 characters and the Unicode line and paragraph separators are written as escapes (`\n`, `\r`, `\x1b`, `\x9b`, …); a stack trace keeps its lines. The JSON handlers, and the console's context, also escape DEL, C1 and the separators, which `jsonEncode` writes as they are.
- `METRICS_TOKEN` set but empty made `/metrics` look protected while a bare `Authorization: Bearer ` matched it; it now stops the boot with a `ConfigException`.
- A Prometheus label value with `\r` is escaped.

### Upgrade notes

- Upgrading can change logs and probes: `/up/ready` no longer shows check errors without `APP_DEBUG`; more context keys are redacted (any containing `pwd`, `jwt`, `dsn`, `bearer`, `credentials`, … whatever their case and `-`/`_`), and map keys that are not strings are written with `toString`; console lines escape control characters, and JSON lines escape DEL, C1 and U+2028/U+2029; a context with more than 10 000 values is cut; an empty `METRICS_TOKEN` stops the boot. New public name: `Loggable` (and `Headers` implements it).
