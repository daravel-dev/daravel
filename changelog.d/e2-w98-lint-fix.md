### Added

- `dartisan lint --fix` applies the fixes the rules offer (the editor quick fixes: `string_validation_rule`, `string_column_name`) to the files `dartisan lint` reads, leaving findings silenced with `// daravel-lint-ignore:` alone, then runs `dart format` on the files it changed and `dart analyze` before and after: a file with more errors than before is put back as it was, and says so. `--dry-run` prints the changed lines and writes nothing. Without `--force` it refuses files with uncommitted changes, and a project outside a git work tree, so `git checkout` can always undo it. After fixing it reports what is left, as `dartisan lint` does.
- `daravel_lints`: `fixSource(source, path, rules:)` applies every fix in a file (a fix left out for an overlap is taken in a later pass), and `lintDirectories` names the folders `dartisan lint` reads.
- `dartisan_cli`: `planLintFixes`, `lintFixDiff`, `uncommittedFiles` and `analyzeErrors` (the pieces of `lint --fix`).

### Upgrade notes

- New public names `fixSource` and `lintDirectories` in `package:daravel_lints`, and `planLintFixes`, `lintFixDiff`, `uncommittedFiles`, `analyzeErrors` and `LintFileFix` in `package:dartisan_cli`: a file that declares one of them and imports the barrel gets an ambiguous-import error.
