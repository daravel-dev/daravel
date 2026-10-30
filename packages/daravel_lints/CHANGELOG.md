# Changelog

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- `invalid_validation_rule` knows `date_format`.

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- `no_sql_string_interpolation` reports `raw`, `select`, `statement` and `insertGetId` only on a database receiver (`DB`, a connection or query builder, a builder chain) and accepts interpolation of literals and `const` names declared in the file.
- `no_mutable_static_in_app` also reports a final static or top-level variable that starts as an empty collection (`static final _hits = <String, int>{}`), and its messages name the shared stores that replace one.

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Version aligned with Daravel 1.14.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- Version aligned with Daravel 1.12.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.11.0

- Version aligned with Daravel 1.11.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

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
