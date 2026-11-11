### Added

- `daravel_lints`: `LintRule.reportsInsideNodes` (default `false`) says whether a rule's `checkAt` reports offsets other than the starts of the nodes its `check` names. `NoInlineJsInterpolation` returns `true`. The editor plugin uses it to walk each file once per rule instead of twice. The plugin also reads only the line of a finding to look for `// daravel-lint-ignore:`, instead of splitting the whole file for every rule.

### Upgrade notes

- `daravel_lints`: an application rule that overrides `checkAt` to report inside nodes should also override `reportsInsideNodes` to return `true`. Otherwise the editor plugin reports its findings at the start of the nodes `check` names. `dartisan lint` is unaffected.
