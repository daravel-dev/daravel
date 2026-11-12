### Added

- `string_column_name` can be enabled like the other opt-in rules (`diagnostics: string_column_name: true`, `dartisan lint --enable=string_column_name`): `LintConfig.rulesIn(root)` builds it over the project's `lib/app/models` (`StringColumnName.forProject`), and `dartisan lint` and `expectLintClean()` run it; `projectRuleNames` lists the opt-in rules built per project.
- `string_column_name` offers its fix: the column string becomes the model's token (`User.cols.email`), named as the query chain names the model; a `const` list loses its `const` (the message then says `(removes const)`); not offered in a list typed `<String>`.
- `daravel_lints_plugin` runs `string_column_name` (opt-in) over the models of each file's package, read through the analysis server (unsaved edits count) and cached until a model file changes (`ModelIndexCache`, `DaravelAnalysisRule.stringColumnName`), with its quick fix and "Fix all in file".
- `ModelColumnIndex.ofSources` builds an index from model sources.

### Upgrade notes

- `daravel_lints`: `LintConfig.rules` still leaves out `string_column_name` (it needs the project); code that runs the configured rules itself should call `LintConfig.rulesIn(root)`. New public names `projectRuleNames` and `ModelIndexCache` (in `daravel_lints_plugin`); a file that declares one of them and imports the barrel gets an ambiguous-import error.
