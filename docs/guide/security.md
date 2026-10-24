# Security

Report vulnerabilities privately as described in
[SECURITY.md](https://github.com/daravel-dev/daravel/blob/main/SECURITY.md).

## Secure by default (BLUEPRINT_V2 §9.2)

| # | Default | Where |
| :-- | :-- | :-- |
| 1 | `APP_DEBUG=true` with `APP_ENV=production` fails at boot unless explicitly allowed | `ConfigValidator` |
| 2 | `APP_KEY` must be 32 bytes; weak keys are refused | `Encrypter` |
| 3 | CORS allows no origin until configured; `*` with credentials is rejected | `CorsMiddleware` |
| 4 | Cookies: sessions arrive in Tier 2 | n/a |
| 5 | `nosniff`, `Referrer-Policy`, `X-Frame-Options` for HTML, HSTS on HTTPS | `SecurityHeadersMiddleware` |
| 6 | Starter throttles `login` (5/min per e-mail + IP) and `register` (5/min per IP) | `bootstrap/app.dart` |
| 7 | Logs redact secrets and never log request bodies | `Logger` |
| 8 | Uploads: multipart arrives in Tier 2; storage paths cannot escape the disk | `normalizeDiskPath` |
| 9 | Generic credential errors; unknown accounts still cost a hash | `equalizeLoginTiming` |
| 10 | `dartisan doctor --production` fails on critical misconfiguration | CLI |

Other built-in controls: `X-Forwarded-*` ignored unless the peer is a
trusted proxy; body size and JSON depth limits; header names and values with
CR, LF or NUL are rejected (no response splitting); JWT verification
rejects `alg: none` and key-type confusion; token secrets are compared in
constant time; SQL is always built from bound values and quoted
identifiers (`daravel_lints` flags string interpolation in raw SQL).

## Security suite (§9.3)

`packages/daravel/test/security/` (tag `security`) runs on every commit:

- OWASP SQL injection payloads as values (stored verbatim) and as
  identifiers (quoted, never executed);
- `X-Forwarded-*` spoofing from untrusted and trusted peers;
- declared and streamed bodies over the limit, deeply nested JSON;
- JWT `alg` manipulation, Ed25519 → HS256 key confusion, tampering, expiry;
- expired personal access tokens;
- storage path traversal (`../`, absolute and Windows paths);
- header injection through handlers;
- ReDoS: every built-in pattern rule on adversarial 100 KB inputs must stay
  under 10 ms;
- seeded property-based fuzzing of the `.env`, cron, cursor and JSON body
  parsers and of bearer-token parsing;
- user enumeration through login timing.

```bash
cd packages/daravel && dart test --tags security
```
