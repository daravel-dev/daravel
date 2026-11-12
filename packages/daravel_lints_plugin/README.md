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

Where a rule offers a fix, the editor offers it as a quick fix, including
"Fix all ... in file". So far that is `string_validation_rule`, which turns
the string into its `Rules` chain. The edits are the rule's own
(`LintRule.fixFor` in `daravel_lints`), so the fix is offered only where the
chain compiles and keeps the meaning.
