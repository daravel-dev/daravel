### Changed

- `dartisan model:sync` no longer compiles the application (#329). It reads the models from their sources and the tables through a database connection the environment configures (`.env`, `DB_*`), from a small program written to `.dart_tool/dartisan/model_sync.dart` that imports only the framework, the CLI and the database drivers, in the versions the project's `pubspec.lock` resolves. Generated code the application no longer accepts is now repaired by syncing again, where the old run stopped with the compiler's errors. `--check` and `--dry-run` work the same way. `--boot` reads through the application as before (it must compile), for a connection configured in code; when that fails on lines `model:sync` wrote, it names them.

### Added

- `model:sync --reset-regions` empties the generated `accessors` and `relation-path` regions (never `statics`), so an application they broke compiles again; with `--dry-run` it only says which.
- `bootstrap/database.dart` (`databaseDrivers`) in new projects and the starter, read by `createApp` through the new `ApplicationBuilder.withDatabaseDrivers` and by `model:sync`; `db:install mysql` (and a driver package installed by name) adds its entries there when the file exists, `bootstrap/app.dart` otherwise.

### Upgrade notes

- `model:sync` in a project without `bootstrap/database.dart` still runs: `sqlite` and `pgsql` are built in, and `daravel_mysql` is used when `pubspec.yaml` depends on it. A project with another driver, or with a connection made in code, adds `bootstrap/database.dart` (as `dartisan new` writes it) or runs `model:sync --boot`. `dartisan upgrade` does not write the file.
- `dart run bin/dartisan.dart model:sync` still compiles the application before it starts; run the global `dartisan model:sync`, or `dart run dartisan_cli:dartisan model:sync`, to sync a project that does not compile.
- New public names: `ApplicationBuilder.withDatabaseDrivers` in `package:daravel/daravel.dart`; `spawnModelSync`, `runModelSyncEntry`, `modelSyncEntrySource`, `modelSyncEntryPath`, `projectDrivers`, `resetModelRegions`, `resettableRegions`, `errorsInGeneratedRegions`, `registerDriverEntries` and `ModelSyncCommand.inEntryFlag` in `package:dartisan_cli`.
