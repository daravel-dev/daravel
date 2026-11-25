### Changed

- `boolean:strict` is now honoured, as Laravel 12.x `validateBoolean` reads it: when the first parameter is exactly `strict` (`boolean:strict`, `boolean:strict,x`, and the alias `bool:strict`), only the values `true` and `false` pass and the error is the `boolean` message under the `boolean` key. It was read as plain `boolean`. Plain `boolean` is unchanged and still accepts `'true'`, `'false'`, `1.0` and `0.0` (ADR-030). `Rules.boolean({strict})`, `BooleanRule(strict:)` and the `boolean({strict})` step of `RuleBuilder` and rule chains build the same rule.

### Upgrade notes

- A request that passed `boolean:strict` with `1`, `0`, `'1'`, `'0'`, `'true'` or `'false'` now fails with 422; send JSON `true` or `false`, or drop `:strict` to keep the lenient rule.
- New public name `BooleanRule.strict` (a field) and a `strict` parameter on `Rules.boolean`, `RuleBuilder.boolean` and `RuleChain.boolean` in `package:daravel` (members of existing classes, so no top-level name is added and no import can clash).
