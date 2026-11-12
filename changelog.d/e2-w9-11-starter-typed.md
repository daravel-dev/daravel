### Changed

- The starter and `dartisan new --template=api` use the typed APIs (wave 9, W9.11): form requests with `Field`s and an input type written by `request:sync`, `postValidated` routes whose handlers take that input (`data.email`, not `data.string('email')`), `Rules` chains and `Rules.of(User.definition).unique(User.cols.email)` instead of rule strings, `User.cols.id` in queries, `Mw.throttle('login')` and `Mw.auth()` instead of middleware strings, and `Config.section<AppConfig>()`. Both turn on the opt-in lints `string_validation_rule` and `prefer_sql_identifier` (`daravel_lints: diagnostics:` in `analysis_options.yaml`) and lint clean.
- The starter's `PATCH /api/users/{id}` validates an `UpdateUserRequest` after the policy check (`validateRequest`), so a stranger still gets 403.
- `dartisan new` writes a template request's input region with `request:sync`'s own code, so the two cannot drift.

### Fixed

- `prefer_sql_identifier` reported the column names `string_column_name` recommends: a typed column (`User.cols.id`, or `cols.id` in the model) and a condition on one (`User.cols.age.gte(18)`). It also reported the `where` static `make:model` writes, which only forwards its argument. Each is now accepted, so the two opt-in lints no longer contradict each other.
