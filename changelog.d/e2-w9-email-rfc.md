### Changed

- `email`, `email:rfc` and `email:strict` use a port of egulias/EmailValidator 4's RFC parser (MIT), the one Laravel uses, instead of an HTML-style pattern. Checked against Laravel 12's own `Validator` with `email`, `email:rfc` and `email:strict` on the 155 text addresses of egulias' test data: no difference.

### Upgrade notes

- `email` (and `email:rfc`) now accepts what Laravel accepts and the old pattern refused:

  | Address | Before | Now (as Laravel) |
  | :-- | :-- | :-- |
  | `user@localhost` | refused | accepted |
  | `"first last"@example.com` | refused | accepted |
  | `user@[127.0.0.1]` | refused | accepted |
  | `user(comment)@example.com` | refused | accepted |
  | `a..b@example.com`, `not-an-email` | refused | refused |

  For the stricter check, use `email:strict` (no RFC warning: refuses the four accepted forms above) or `email:filter` (PHP's `FILTER_VALIDATE_EMAIL`, which needs a dot in the domain). The pattern `client:flutter` writes into Flutter form validators is now a loose shape (`something@domain`), so the client never refuses an address the server accepts.
