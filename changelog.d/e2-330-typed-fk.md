### Added

- `model:sync` types foreign keys (#330): a one-column foreign key to the primary key of a model with a typed id gets that type (`AssessmentId get assessmentId`, nullable as the column is) in its getter, setter, `cols` token, `createWith` and `updateWith`, read from the table's constraints (`Schema.getForeignKeys`); a key to the model's own table takes its own id. Left `int`: a referenced model without a typed id (one line says so), a table no model maps (one summary line) or two models map (a warning), a composite key, a key to another column, a column the model casts itself, and a driver that does not report foreign keys.
- When the typed id of a foreign key is declared in another model file that the file does not import yet (itself, or through `models.dart`), `model:sync` adds one import line at its sorted place (or after the last import), prints it, and honours `--dry-run` and `--check`; it never removes or reorders imports.
- `model:sync Attempt AttemptItem --typed-ids`: several models in one run.
- New in `package:dartisan_cli`: `foreignIdTypes`, `addModelImports`, `untypeStatics`, `hasTypedIds` and `TypedModel`; `columnType`, `colsLines`, `planAccessors`, `typedWriteLines` and `syncModelSource` take `foreignIds:`.

### Changed

- Typed ids are opted in per model and the opt-in stays in the source (#330): a model with a `<dartisan:ids>` region keeps its typed id when `model:sync` runs without `--typed-ids` (it used to write the untyped version back), and `--typed-ids` opts in only the models the run syncs. Deleting the region opts a model out: the next sync gives `find`/`findOrFail` back their `Object` parameter.
- `dartisan_cli` depends on `analyzer` directly (it already came through `daravel_lints` and `dart_style`).

### Upgrade notes

- `model:sync` without `--typed-ids` no longer removes typed ids from models that have a `<dartisan:ids>` region; to go back to untyped ids, delete the region (and any `idType:`) and sync. A project that uses typed ids sees its foreign keys typed on the next sync: code that passes a plain `int` where a foreign key now takes an `AssessmentId` needs `AssessmentId(n)`, and code that passed a cast (`AssessmentId(session.assessmentId)`) still compiles.
- New public names in `package:dartisan_cli` (`foreignIdTypes`, `addModelImports`, `untypeStatics`, `hasTypedIds`, `TypedModel`): a project command file that declares one of them and imports the barrel gets an ambiguous-import error.
