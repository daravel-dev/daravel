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
(`prefer_sql_identifier`, `string_validation_rule`, `string_column_name`)
are turned on by name:

```yaml
plugins:
  daravel_lints_plugin:
    version: ^1.27.0
    diagnostics:
      prefer_sql_identifier: true
      string_column_name: true
```

`string_column_name` reads only the models a file refers to, from
`lib/app/models` of the file's package. It reads them as the editor holds
them, unsaved changes included, and reads a model again only when it
changes. A model the file does not import is not resolved, so the editor
does not report it; `dartisan lint` still does.

A finding is silenced as with `dartisan lint`
(`// daravel-lint-ignore: <rule>` on its line) or with the analyzer's
`// ignore: <rule>`. The rules and their checks live in `daravel_lints`;
this package only runs them for the analysis server, which resolves it
apart from your application, so its pinned `analyzer` never reaches your
dependencies.

Where a rule offers a fix, the editor offers it as a quick fix, including
"Fix all ... in file". So far there are two:
- `string_validation_rule` turns the string into its `Rules` chain;
- `string_column_name` turns the column string into the model's token
  (`User.cols.email`).

The edits are the rule's own (`LintRule.fixFor` in `daravel_lints`), so a
fix is offered only where the result compiles and keeps the meaning.
