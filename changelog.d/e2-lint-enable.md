### Added

- `dartisan lint` runs the opt-in rules a project enables. It reads them from `diagnostics:` in the project's `analysis_options.yaml`: under `plugins: daravel_lints_plugin:` (the block the editor plugin reads) or, without the plugin, under a top-level `daravel_lints:` block of the same shape, which the analyzer ignores. `true` turns an opt-in rule on and `false` turns a default rule (or `registry_entry_missing`) off.
- When both blocks exist, the plugin's is read and a warning says the other was ignored. Only the project's own file is read: `include:` is not followed (a warning says so when the file includes a local file and has no block of its own), and in a pub workspace the file is the one of the package `dartisan` runs in.
- An unknown rule name or a value other than `true`/`false` exits 64 and lists the rule names. `--enable=<rule>` and `--disable=<rule>` change one run, and the summary line names the opt-in rules that ran and the rules turned off.
- `daravel_lints`: `lintConfig(root)` returns a `LintConfig` (`rules`, `registries`, `withOverrides`, `warnings`); `lintProject` gains `registries:`. `daravel_test`: `expectLintClean()` reads the same configuration, so an architecture test and `dartisan lint` agree.

### Upgrade notes

- New public names `LintConfig`, `lintConfig` and `registryRuleName` in `package:daravel_lints`. If an application declares one of these names, importing `package:daravel_lints` makes the reference ambiguous; `hide` the package's name or rename yours.
- `expectLintClean()` now applies the `diagnostics:` of `analysis_options.yaml`. A project whose file already has a `plugins: daravel_lints_plugin: diagnostics:` block now runs those settings in its architecture test too. Without such a block, nothing changes.
