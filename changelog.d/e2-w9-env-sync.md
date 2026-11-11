### Added

- `dartisan env:sync [--check]` (wave 9, W9.7): writes `lib/config/env_keys.dart` from `.env.example`, an `EnvKey<T>` per variable (`int`, `bool` or `String` from the example value, `# @type String` to override; a commented-out variable is optional and its key nullable) with the comments above it as documentation. Only `.env.example` is read, never `.env`, and an example value is copied into the documentation only when it cannot be a credential. `--check` exits 1 when the file is out of date.
- `EnvKey<T>` (an environment variable name that is its string, `implements String`) and `Env.of(key, [fallback])`, which reads it as its type.

### Upgrade notes

- `package:daravel` exports `EnvKey` (from `src/foundation/env.dart`), and `Env` has `of`.
