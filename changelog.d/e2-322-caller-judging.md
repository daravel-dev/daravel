### Changed

- `prefer_sql_identifier` judges a query that starts at a model's static (`Region.where(sort)`, the passthrough `make:model` writes into the statics region) at the caller (#322); the passthrough itself stays unreported. A model is a class in `lib/app/models` that extends `Model`, directly or through a class of that folder (`ModelColumnIndex.modelClasses`); `dartisan lint` and `expectLintClean()` read them (`LintConfig.rulesIn`), and the editor plugin asks the resolved class (`ModelIndexCache.modelClassesIn`, `DaravelAnalysisRule.preferSqlIdentifier`). `PreferSqlIdentifier(modelClasses:)` takes them; `const PreferSqlIdentifier()` knows none and behaves as before.

### Upgrade notes

- Upgrading can change what `prefer_sql_identifier` reports: a project that enables it can get new findings on `Model.where(variable)` and the other column methods called on a model class (`Region.orderBy(sort)`). Write the column as a literal, a `cols` token or a `SqlIdentifier`, as for any other query.
