### Added

- `unique` and `exists` read the `column,value` where conditions Laravel reads after their arguments, so rules move from Laravel as they are: `unique:users,email,NULL,id,deleted_at,NULL`, `exists:users,id,active,1,role,!guest`.
- They follow Laravel 13's `getExtraConditions` and `DatabasePresenceVerifier::addWhere`: `NULL` is `whereNull`, `NOT_NULL` is `whereNotNull`, a value starting with `!` is `!=`, and any other value is `=`.
- A column given twice keeps its first place and its last value, as in the PHP array Laravel builds.
- The values are always bound. A column that is not a plain identifier is refused before any query runs. Tested on SQLite, PostgreSQL 16 and MySQL 8.4.

### Changed

- An odd number of condition arguments (a column without a value, `exists:users,id,active`) is an `ArgumentError` when the rule is parsed; Laravel fails there too. The `invalid_validation_rule` lint reports it. Before this change, any condition argument was refused.

### Fixed

- `unique:table,column,[id]` read the key to skip from the input field `id` in Laravel and as the literal text `[id]` here, so updating a row with its own unchanged value failed. The ignore now follows Laravel's `prepareUniqueId`: `[field]` (also `[user.id]`) is read from the input when the rule runs; `null` in any case skips nothing; an integer with surrounding whitespace or a sign is that integer (`' 1'` is `1`; `'01'` stays text); backslashes are stripped.
