<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_lints_plugin

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_lints_plugin/README.id.md)

The [`daravel_lints`](https://pub.dev/packages/daravel_lints) rules in the
editor: a Dart analysis server plugin (`analysis_server_plugin`), so the
findings of `dartisan lint` appear as you type, in VS Code, Android Studio
and IntelliJ, and in `dart analyze`.

Enable it in the project's `analysis_options.yaml` (the top-level
`plugins:` section, Dart 3.10 and later), then restart the analysis server:

```yaml
plugins:
  daravel_lints_plugin: ^1.27.0
```

The rules `dartisan lint` runs by default are on. The opt-in rules
(`prefer_sql_identifier`) are turned on by name:

```yaml
plugins:
  daravel_lints_plugin:
    version: ^1.27.0
    diagnostics:
      prefer_sql_identifier: true
```

A finding is silenced as with `dartisan lint`
(`// daravel-lint-ignore: <rule>` on its line) or with the analyzer's
`// ignore: <rule>`. The rules and their checks live in `daravel_lints`;
this package only runs them for the analysis server, which resolves it
apart from your application, so its pinned `analyzer` never reaches your
dependencies.

## Working on the rules

The analysis server builds the plugin in a space of its own and resolves
its dependencies there, from pub.dev, even when `analysis_options.yaml`
points at the plugin with `path:`. A rule changed in this repository's
`daravel_lints` therefore does not reach the editor until it is
released, and a plugin that uses a newer `daravel_lints` API fails to
build in the analysis server ("isn't defined"). To try unreleased rules,
override the dependency for the plugin too:

```yaml
plugins:
  daravel_lints_plugin:
    path: packages/daravel_lints_plugin
  dependency_overrides:
    daravel_lints:
      path: packages/daravel_lints
```

`dart test` in this package uses the workspace's `daravel_lints`, so the
tests guard the code being changed. For the same reason, the published
plugin requires the `daravel_lints` of its own release (`^<version>`,
checked by `tool/publish_checks.dart`), and `daravel_lints` is published
first.

## What it costs

Measured with `tool/editor_latency.dart` (the analysis server over LSP, as
the editors run it, 10 edits per series) on the Daravel repository, a
workspace of about thirty packages, on Windows, with the rules of
`daravel_lints` 1.27.0 as published (see above):

- **Per edit: nothing measurable.** The plugin's findings arrive in the
  same diagnostics message as the analyzer's: 15 to 21 ms (median) with
  the plugin, 34 to 35 ms without it, which is noise between series.
- **Memory: the analysis server's working set grows by about 430 to
  700 MB** (1.16 to 1.44 GB with the plugin, 0.73 to 0.83 GB without). The
  plugin runs in its own isolate with its own copy of the analysis.
- **Start-up: the first start can take tens of seconds.** In the first
  series after the plugin was enabled, its first finding came 15 s after
  the edit (an earlier one timed out at 30 s). Later starts took 0.06 to
  0.23 s after the server's own analysis. That the cost is the server
  building the plugin once per plugin version is an assumption, not
  measured.

Measured again with this repository's rules (`dependency_overrides`
above, after the change that walks each file once per rule), three
series: 20 and 29 ms per edit (median), and 148 ms in a first series
whose spread (13 to 318 ms) suggests a busy machine; a working set of
1.17 to 1.23 GB; a start-up of 1.9 to 10.5 s, longer than with the
published package (that the server resolves the overridden path again
is an assumption, not measured).

A large workspace on a machine with little memory may prefer to keep the
plugin off and run `dartisan lint` instead; the rules are the same.

## In CI

`dart analyze` runs the plugin too, so its findings appear there as
`info`, and `dart analyze --fatal-infos` fails on them, as `dartisan lint`
does. A CI job that runs both reports each finding twice, which is
harmless: both fail on it. Keep `dartisan lint` in CI either way, since
it also runs the registry check (`registry_entry_missing`), which the
plugin does not.
