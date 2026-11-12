### Changed

- The global `dartisan request:sync` no longer compiles the application: it runs in the project's own `dartisan_cli` (`dart run dartisan_cli:dartisan`, the version the project's `pubspec.lock` resolves), since it only reads and writes sources. It now works while the project does not compile, such as after a request is changed to `FormRequest<StoreNoteRequestInput>` before that type exists, where every command of `bin/dartisan.dart` failed to compile, the one that writes the type included. `model:sync` still runs in the application, since it reads the database through its connection; `--help` of both says so.

### Upgrade notes

- New public names in `package:dartisan_cli`: `GlobalDartisanRunner.runsFromSource`, `GlobalDartisanRunner.inProjectPackage`, and the `environment` and `directory` parameters of `GlobalDartisanRunner.execute`.
