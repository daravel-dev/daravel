### Added

- `daravel_lints` fixes (W9.8): `LintRule.fixFor(unit, node)` returns a `LintFix` (message and text edits, `apply(source)`), `LintRule.fixesIn(unit)` every fix in a file, and `LintFixMerger` combines them so an edit two fixes share is made once; `daravelName` and `leaveConstantContext` are the helpers a fix uses to name a `package:daravel` member and to leave a constant context.
- `string_validation_rule` offers its fix: the string rule list becomes the `Rules` chain the finding names (`ruleChainSource`), with the import's prefix or an added import. Not offered for interpolated or adjacent strings, in a list or map typed to hold strings (also through a `rules()` return type), in a `const` variable or `const` constructor call, or when the import hides `Rules`; a `const` list or map loses its `const` when that is enough.
- `daravel_lints_plugin` offers each rule's fix as a quick fix, with "Fix all in file" (`DaravelFix`); today that is `string_validation_rule`.

### Upgrade notes

- `daravel_lints`: new public names `LintFix`, `LintEdit`, `LintFixMerger`, `daravelName` and `leaveConstantContext`; a file that declares one of them and imports the barrel gets an ambiguous-import error (`hide` them or rename yours). A `LintRule` subclass written outside Daravel needs no change (`fixFor` returns null by default), unless it declares its own `fixFor` or `fixesIn` with another signature.
- `daravel_lints_plugin`: new public name `DaravelFix`, and a new dependency on `analyzer_plugin` (`>=0.14.19 <0.15.0`, already a dependency of `analysis_server_plugin`).
