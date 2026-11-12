### Added

- `string_column_name` can be enabled like the other opt-in rules (`diagnostics: string_column_name: true`, `dartisan lint --enable=string_column_name`): `LintConfig.rulesIn(root)` builds it over the project's `lib/app/models` (`StringColumnName.forProject`), and `dartisan lint` and `expectLintClean()` run it; `projectRuleNames` lists the opt-in rules built per project.
- `string_column_name` offers its fix: the column string becomes the model's token (`User.cols.email`), named as the query chain names the model; a `const` list loses its `const` (the message then says `(removes const)`); not offered in a list typed `<String>`.
- `daravel_lints_plugin` runs `string_column_name` (opt-in) over the models each file refers to (resolved by the analysis server, under `lib/app/models` of the file's package), each read through the server (unsaved edits count) and parsed once per modification stamp, so a file analysis costs under 1 ms with 200 models (0.6 to 0.7 ms measured on Windows) (`ModelIndexCache`, `DaravelAnalysisRule.stringColumnName`), with its quick fix and "Fix all in file".
- `ModelColumnIndex.ofSources` and `ModelColumnIndex.merge` build an index from model sources or other indexes.

### Upgrade notes

- `daravel_lints`: `LintConfig.rules` still leaves out `string_column_name` (it needs the project); code that runs the configured rules itself should call `LintConfig.rulesIn(root)`. New public names `projectRuleNames` and `ModelIndexCache` (in `daravel_lints_plugin`); a file that declares one of them and imports the barrel gets an ambiguous-import error.
