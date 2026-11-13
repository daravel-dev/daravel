### Fixed

- Security: a model that lists `guarded` columns (and no `fillable`) could have them mass assigned through a key spelled differently: with surrounding spaces (`'role '`, trimmed by the query grammar), in another letter case (`'ROLE'`, on SQLite and MySQL), qualified by the table (`'users.role'`, on MySQL) or as a JSON path into a guarded JSON column (`'meta->role'`), through `fill`, `create`, `update`, `firstOrCreate`, `updateOrCreate`, `newInstance` and a relation's `create`. `ModelDefinition.isFillable` now decides as Laravel's `GuardsAttributes::isFillable`: with guarded columns, only a plain identifier (`^[A-Za-z_][A-Za-z0-9_]*$`) that is not guarded in any letter case is fillable, and a key with a `.` or starting with `_` never is. Affected since 1.0.0. Until you upgrade, list `fillable` instead of `guarded` (a `fillable` list matches keys exactly and was not affected).

- `dartisan model:sync` decides which columns get `createWith`/`fillWith` parameters by the same rule, so it no longer writes a parameter that `fill` discards (a column starting with `_`, or one guarded in another letter case).

### Upgrade notes

- Upgrading can change which keys mass assignment accepts on a model with `guarded` columns and no `fillable`: a key that is not a plain identifier (a JSON path such as `'settings->theme'`, a key with spaces or other characters) is now discarded, or refused with `MassAssignmentException` under `Model.preventSilentlyDiscardingAttributes`, as Laravel refuses a key that is not a column of the table. With `guarded: []`, keys with a `.` or a leading `_` are discarded, as in Laravel. Set such attributes with `setAttr` or `forceFill`, or list them in `fillable`.
