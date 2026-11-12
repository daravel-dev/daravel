### Added

- `bootTestApp(createApp, env: {...})` in `daravel_test` creates the application with the test environment and the current directory as base path, and boots it; shutting it down stays in the test. `testEnv([overrides])` is that environment (`APP_ENV=testing`, `DB_CONNECTION=sqlite`, `DB_URL=sqlite::memory:`, overrides last), also for `refreshDatabase`. `TestAppFactory` names the type of `createApp` as `dartisan new` writes it. The starter's tests, `dartisan new` and `make:test` use them.

### Upgrade notes

- New public names in `package:daravel_test/daravel_test.dart`: `bootTestApp`, `testEnv` and `TestAppFactory`. A project that declares any of these names itself and imports `daravel_test` without a prefix now gets an ambiguous name; rename its own or hide them (`import 'package:daravel_test/daravel_test.dart' hide testEnv;`).
