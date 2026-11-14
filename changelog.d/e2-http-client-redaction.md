### Added

- `redactUrl(url)`: a URL with the user-info password and the values of sensitive query parameters (`token`, `api_key`, `password`, `signature`, ...) masked, for messages and logs; it needs no valid URL. A fragment of `name=value` pairs (an OAuth implicit-flow redirect, `#access_token=…`) is masked the same way. `sensitiveKeyNames`, `normalizeKeyName` and `isSensitiveKeyName` are the names and the comparison the logger's redaction uses (`LoggingConfig.defaultRedactedKeys` is `sensitiveKeyNames`). `Http.isIdempotent(method)` and `ConnectionException.method`.

### Fixed

- Security: the HTTP client's errors (`ConnectionException`, `ResponseTooLargeException`, `StrayRequestException`, a malformed URL) quoted the request URL whole, user-info password and query tokens included, into messages, logs and the debug error page. They now show it through `redactUrl`; the request and `ResponseTooLargeException.url` keep it for code. Since 1.0.0.
- Security: `redactUrlPassword` left a password in a URL without a valid scheme (`app:secret@host/db`, `postgres//app:secret@host`) and masked only the end of one holding `:` (`app:p1:p2@host`). Everything from the first `:` of the user info to the last `@` is now masked; without `://` before the `@` after a valid scheme, the user info starts at the beginning of the text, so a password holding `://` (`app:pa://ss@host`) is masked too. A malformed `DB_URL`, `REDIS_URL`, `UPSTREAM_URL`, `AWS_ENDPOINT` (`daravel_s3`) or `Env.url` value is reported through `redactUrl`, query passwords included; `daravel_reverb`'s `config:show` masks `REVERB_METRICS_URL` even when `Uri` cannot parse it.
- `Http.retryOnConnectionOr5xx` and `Http.retryOnConnectionOnly` sent a `POST` or `PATCH` that timed out again, although the server may have processed it (measured: three bodies received). They now retry a timeout only for an idempotent method (RFC 9110: `GET`, `HEAD`, `OPTIONS`, `TRACE`, `PUT`, `DELETE`); a connection that failed before sending is still retried.
- A failed broadcast to Reverb or Pusher quoted the whole response body; it is cut to 120 characters, as Laravel's `RequestException` cuts it.
- A timeout under a second read `0s` in the error message; it now reads in milliseconds.
- `daravel_redis`: a password holding `:` in `REDIS_URL` (also Sentinel and Cluster URLs) was read as no password; it is kept whole.
- Logging: a value whose `toString()` threw (in the context, from `toLogValue()`, or the record's error) made the JSON and daily-file handlers drop the record; it is written as `[UNLOGGABLE: <type>]`. The console escapes the channel name too, and the error of a failed readiness check is logged through `redactUrl`.

### Upgrade notes

- Upgrading can change logs and messages: a log context key containing `signature` (`auth_signature`, `X-Amz-Signature`, `signature`) is now redacted, since `signature` joined the default `LOG_REDACT` keys, and so are query and fragment values with such names; URL-bearing errors show masked URLs; a timed-out `POST` or `PATCH` is no longer retried by the two helpers. New public names: `redactUrl`, `sensitiveKeyNames`, `normalizeKeyName`, `isSensitiveKeyName`, `Http.isIdempotent`, `ConnectionException.method`.
