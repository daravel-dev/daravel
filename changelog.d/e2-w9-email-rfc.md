### Changed

- `email`, `email:rfc` and `email:strict` use a port of egulias/EmailValidator 4's RFC parser (MIT), the one Laravel uses, instead of an HTML-style pattern: quoted local parts, comments, domain literals and single-label domains (`a@b`) pass `email` and `email:rfc` as in Laravel, and `email:strict` refuses any address with an RFC warning. Checked against Laravel 12's own `Validator` on the 155 text addresses of egulias' test data.

### Upgrade notes

- `email` accepts some addresses it refused before (`"first last"@example.com`, `user@[127.0.0.1]`, `user@localhost`), exactly as Laravel does. An application that relied on the stricter check can use `email:strict`, or `email:filter` (PHP's `FILTER_VALIDATE_EMAIL`, which needs a dot in the domain).
