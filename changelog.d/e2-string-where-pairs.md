### Added

- `unique` and `exists` read the `column,value` where conditions Laravel reads after their arguments, so rules move from Laravel as they are: `unique:users,email,NULL,id,deleted_at,NULL`, `exists:users,id,active,1,role,!guest`.
- They follow Laravel 13's `getExtraConditions` and `DatabasePresenceVerifier::addWhere`: `NULL` is `whereNull`, `NOT_NULL` is `whereNotNull`, a value starting with `!` is `!=`, and any other value is `=`.
- A column given twice keeps its first place and its last value, as in the PHP array Laravel builds.
- The values are always bound. A column that is not a plain identifier is refused before any query runs. Tested on SQLite, PostgreSQL 16 and MySQL 8.4.
- New public names `UniqueRule.ignoreFrom` (the input field whose value is the key to skip) and `UniqueRule.skippedKey` (Laravel's reading of an ignore value). They are public because the string parser is a separate library.

### Changed

- An odd number of condition arguments (a column without a value, `exists:users,id,active`) is an `ArgumentError` when the rule is parsed; Laravel fails there too. The `invalid_validation_rule` lint reports it. Before this change, any condition argument was refused.

### Fixed

- `unique:table,column,[id]` read the key to skip from the input field `id` in Laravel and as the literal text `[id]` here, so updating a row with its own unchanged value failed. The ignore now follows Laravel's `prepareUniqueId`: `[field]` (also `[user.id]`) is read from the input when the rule runs; `null` in any case skips nothing; an integer with surrounding whitespace or a sign is that integer (`' 1'` is `1`; `'01'` stays text); backslashes are stripped.
- `exists` on a list of values (`exists:users,id` for `ids: [1, 3]`) failed with a database error, a 500: the list was bound as one value. It now counts the distinct values found with `whereIn`, as Laravel's `getMultiCount`, also with where conditions.
- `exists` and `unique` with a list or a map sent by the client made a database error, a 500: a list holding a list or a map, or `unique` with any list, was bound as one value, and a list longer than a query's placeholders (SQLite 32 766) failed in the driver. Now, as Laravel 13 reads them: a map is its values; `unique` checks the first value of a list (Laravel's `flattenValue`), and an empty one passes; `true` is 1 and `false` matches nothing; `exists` counts distinct values as PHP's `array_unique` does (`1`, `1.0`, `"1"` and `true` are one). Unlike Laravel, an `exists` list holding a list or a map fails the rule (Laravel accepts one such element by accident and throws for more), and a list of more than `ExistsRule.maxListValues` (10 000) distinct values fails it without a query (Laravel gets a database error).

### Upgrade notes

- A string `unique:` or `exists:` with an odd number of condition arguments (a column without its value) is an `ArgumentError` when a request first validates with it or a test does. `dartisan lint` (`invalid_validation_rule`) finds these strings before any request.
- A string `unique:table,column,[field]` now skips the row whose key is the value of the input field `field`, as in Laravel. Before, it skipped a row whose key was the literal text `[field]`.
- New public names `UniqueRule.ignoreFrom`, `UniqueRule.skippedKey` and `ExistsRule.maxListValues`.
- An `exists` list of more than 10 000 distinct values now fails the rule; validate such lists in chunks yourself if you need them.
