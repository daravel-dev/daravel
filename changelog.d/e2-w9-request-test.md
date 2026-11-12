### Added

- `expectFormRequestTyped(form, input, read: (input) => input.typed)` in `daravel_test` (wave 9, W9.5): validates a sample input with a typed form request and reads every field as its declared type, so a `Field<T>` whose rules do not guarantee `T` (a `Field<int>` with only `required`) fails a test instead of throwing in the handler as a 500. `authorize` is not run; `prepare` and `passed` are. A failure names the request class and the failed rules or the mistyped field, never the input values.
- `Validator.failed()`: the rules that failed in the last run, by attribute (Laravel's `$validator->failed()`, rule names only, without parameters).
- `request:sync` adds `Map<String, Object?> get typed` to the input type: every field by its input key, already converted (left out, with a note, when a field is named `typed`). The region is laid out as `dart format` would for any name length.
- `make:request` also writes `test/unit/requests/<name>_test.dart` with an `expectFormRequestTyped` call when the project depends on `daravel_test`, and the request it writes is already in sync.

### Upgrade notes

- `package:daravel_test` exports `expectFormRequestTyped` (from `src/form_request.dart`).
