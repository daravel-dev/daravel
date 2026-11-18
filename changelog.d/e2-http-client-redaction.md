### Added

- `redactUrl(url)` masks user-info passwords, including those of URLs nested in its path or query, and sensitive query and fragment values for messages and logs. `redactUrlInText(text)` masks every URL in free-form messages: each `scheme://` starts one, whatever separates it from the text before, and each URL is masked within itself, so a URL without credentials beside one with credentials stays whole. `sensitiveKeyNames`, `normalizeKeyName`, and `isSensitiveKeyName` provide the shared names and comparisons used by URL redaction and logging.
- `Http.isIdempotent(method)`, `ConnectionException.method`, and `ConnectionException.mayHaveBeenSent` support retry decisions based on the request method and connection phase.

### Fixed

- HTTP client, S3, configuration, upstream, and metrics-command messages display URLs through the shared redactor. Request objects and `ResponseTooLargeException.url` retain their values for application code.
- `Http.retryOnConnectionOr5xx` and `Http.retryOnConnectionOnly` retry connection failures after possible delivery only for idempotent methods. Failures before connection opening remain retryable. Selecting `retryOnConnectionOr5xx` opts into retrying responses with status 429 or 5xx for every method.
- Broadcast error summaries are limited to 120 characters. Sub-second timeout messages use milliseconds.
- Redis URL configuration preserves complete user-info passwords for standalone, Sentinel, and Cluster connections.
- Log handlers render values that cannot be converted to text as `[UNLOGGABLE: <type>]`, escape console channel names, and redact every URL in readiness messages.

### Upgrade notes

- Upgrading can change logs and messages: the default `LOG_REDACT` names include `signature`; URL-bearing messages mask sensitive values; retry helpers require an idempotent method after possible delivery. New public names: `redactUrl`, `redactUrlInText`, `sensitiveKeyNames`, `normalizeKeyName`, `isSensitiveKeyName`, `Http.isIdempotent`, `ConnectionException.method`, `ConnectionException.mayHaveBeenSent`.
