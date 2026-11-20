### Fixed

- The console log handler wrote a message's and an error's control characters as they were: a `\r\n` carried in a route parameter or a header forged a log line, and an ESC reached the terminal. C0 (tab kept), DEL and C1 characters and the Unicode line and paragraph separators are written as escapes (`\n`, `\r`, `\x1b`, `\x9b`, …); a stack trace keeps its lines. The JSON handlers, and the console's context, also escape DEL, C1 and the separators, which `jsonEncode` writes as they are.
- `METRICS_TOKEN` set but empty made `/metrics` look protected while a bare `Authorization: Bearer ` matched it; it now stops the boot with a `ConfigException`.
- A Prometheus label value with `\r` is escaped.

### Upgrade notes

- Upgrading can change logs and boot checks: console lines escape control characters, and JSON lines escape DEL, C1 and U+2028/U+2029; an empty `METRICS_TOKEN` stops the boot.
