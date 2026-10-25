# Changelog

## 1.2.0

- Version aligned with Daravel 1.2.0; no rule changes.

## 1.1.0

- `unawaited_in_db_transaction`: queries started inside `DB.transaction` without `await` (including `unawaited(...)` and `.ignore()`).
- `invalid_validation_rule`: unknown rule names and missing or non-numeric arguments in rule strings.

## 1.0.0

- Version aligned with the Daravel 1.0.0 release; no rule changes.

## 1.0.0-beta.3

- Version aligned with the Daravel 1.0.0-beta.3 release; no rule changes.

## 1.0.0-beta.2

- Version aligned with the Daravel 1.0.0-beta.2 release; no rule changes.

## 1.0.0-beta.1

First public beta: `no_dart_mirrors`, `no_print_in_app`, `no_mutable_static_in_app`, `no_sql_string_interpolation` and registry checks for `bootstrap/` (`registry_entry_missing`).

The full history of the Daravel workspace is in the
[repository changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).
