### Added

- `daravel_test`: `runDartScript(script, arguments:, environment:)` runs a Dart program as a process of its own for a test of what only a process shows (its output after a shutdown, its exit code). It runs on the bare VM (`dartvm`) with the workspace's package config instead of `dart run`, which copies the native assets again: on Windows a test runner that has already opened SQLite holds `.dart_tool/lib/sqlite3.dll`, and that copy failed. It falls back to `dart run` on an SDK without `dartvm`.

### Upgrade notes

- `daravel_test`: new public name `runDartScript` in `package:daravel_test` (a test helper of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
