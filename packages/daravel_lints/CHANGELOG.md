# Changelog

## 1.10.1

- Version aligned with Daravel 1.10.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.10.0

- Version aligned with Daravel 1.10.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.9.0

- Version aligned with Daravel 1.9.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.8.1

- Version aligned with Daravel 1.8.1; no changes.

## 1.8.0

- Version aligned with Daravel 1.8.0; no changes.

## 1.7.0

- Version aligned with Daravel 1.7.0; no changes.

## 1.6.0

- Version aligned with Daravel 1.6.0; no changes.

## 1.5.1

- Version aligned with Daravel 1.5.1; no changes.

## 1.5.0

- Version aligned with Daravel 1.5.0; no changes.

## 1.4.1

- Version aligned with Daravel 1.4.1; no changes.

## 1.4.0

- Version aligned with Daravel 1.4.0; no rule changes.

## 1.3.0

- `invalid_timezone`: zone names in `.timezone('...')` must be IANA zones (suggests the right case).
- `registry_entry_missing` checks `lib/app/models` against `bootstrap/models.dart` when that file exists.

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
