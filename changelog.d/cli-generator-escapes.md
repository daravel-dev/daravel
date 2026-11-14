### Changed

- `client:flutter`: the generated runtime's `dispositionFilename` returns only a file name to save under: the part after the last `/` or `\`, without control characters, leading spaces or trailing spaces and dots, and `null` when nothing is left (a name of dots only); Windows device names (`CON`, `NUL`) are not refused. A route's summary and path, a model's description and the application's name are written into `///` comments on one line, and into `pubspec.yaml` as one quoted value.
- Generators write outside values (column names in `model:sync`, `.env` keys in `env:obfuscate`, route names and paths in `names:sync`, `make:migration --create/--table`, `make:model --table`, `make:command --command`) as escaped Dart string literals and one-line comments, so a quote, `$`, backslash or line break in them stays part of the value. `request:sync` copies a `Field` key's literal as written (it no longer escapes it a second time) and reads a key only from a literal on one line.
- `env:obfuscate`: a variable with no letter or digit (`_`) is named `value`, a reserved word gets `Value` (`IF` is `ifValue`), and names that clash get a number (`FOO_BAR` and `FOO__BAR` are `fooBar` and `fooBar2`). `--class` must be a class name (letters and digits).
- `build --docker` writes `Dockerfile` and `.dockerignore` each only when it does not exist yet, or with `--force`.
- `coordinator:stats` sends the application's `METRICS_TOKEN` without `--token` only to `APP_URL`'s host or a loopback address; to another host it is a usage error unless `--token` is passed.

### Upgrade notes

- Regenerate clients made with `client:flutter` (`dartisan client:flutter`) so that their `runtime.dart` carries the new `dispositionFilename`.
- `coordinator:stats --url=<another host>` with `METRICS_TOKEN` configured now needs `--token`. `build --docker` no longer replaces an existing `.dockerignore` without `--force`.
