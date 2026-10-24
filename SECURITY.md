# Security policy

## Supported versions

| Version | Supported |
| :-- | :-- |
| 1.0.0-beta.x | Yes: security fixes are released as new beta versions |
| < 1.0.0-beta | No |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub: open the repository's **Security** tab and
choose **Report a vulnerability** (GitHub private vulnerability reporting).
Include:

- the affected package and version (`dartisan about` prints it);
- a description of the issue and its impact;
- steps or a minimal project to reproduce it;
- any suggested fix.

What to expect:

1. Acknowledgement within 3 working days.
2. An initial assessment (confirmed, needs information, or not a
   vulnerability) within 10 working days.
3. A fix developed in a private fork, with a regression test added to the
   security suite (`packages/daravel/test/security`).
4. A release with a GitHub security advisory and a `CHANGELOG.md` entry that
   credits the reporter, unless you prefer to stay anonymous.

We ask that you give us a reasonable time to release a fix before any public
disclosure (90 days by default, shorter for issues being actively exploited).

## Scope

In scope: the `daravel`, `daravel_test`, `daravel_lints` and `dartisan_cli`
packages, the `dartisan new` templates and the starter application,
including the Laravel-compatible formats they read and write (tokens,
hashes, encrypted payloads, signed URLs).

Out of scope: vulnerabilities in your own application code, in the Dart SDK
or in third-party packages (report those upstream; we will update our
constraints), and issues that need a compromised `APP_KEY` or database.

## How security is maintained

- Secure defaults and the threat model are documented in
  `docs/guide/security.md` (BLUEPRINT_V2 §9).
- The security regression suite (tag `security`) runs on every commit on
  Linux, Windows and macOS: SQL injection payloads, proxy header spoofing,
  body limits, JWT manipulation, expired tokens, path traversal, header
  injection, ReDoS budgets, parser fuzzing and login timing.
- Cryptography uses `package:cryptography`, `package:crypto` and
  `package:bcrypt`; Daravel does not implement primitives itself.
