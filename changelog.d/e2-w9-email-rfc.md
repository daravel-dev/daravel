### Changed

- `email`, `email:rfc` and `email:strict` use a port of egulias/EmailValidator 4's RFC parser (MIT), the one Laravel uses, instead of an HTML-style pattern. Checked against Laravel 12's own `Validator` with `email`, `email:rfc` and `email:strict` on the 155 text addresses of egulias' test data: no difference.

### Upgrade notes

- `email` (and `email:rfc`) now accepts, as Laravel does, addresses the old pattern refused: before, `user@localhost`, `"first last"@example.com`, `user@[127.0.0.1]` and `user(comment)@example.com` were refused; now they are accepted. `a..b@example.com` and `not-an-email` are still refused. For the stricter check use `email:strict` (no RFC warning: it refuses those four) or `email:filter` (PHP's `FILTER_VALIDATE_EMAIL`, which needs a dot in the domain).
- The pattern `client:flutter` writes into Flutter form validators for `email` is now a loose shape (`something@domain`), so the client never refuses an address the server accepts.
