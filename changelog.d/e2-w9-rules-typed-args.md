### Added

- Validation: typed rule arguments (wave 9, W9.4b). `Field<T>` names an input field once (`static const email = Field<String>('email')`): it is the key of `rules()`, `messages()` (`email.on(Rules.required())` is `email.required`) and `attributes()`, and any rule argument that takes a field name (`Rules.same(password)`), so a misspelt field does not compile. `Rules.of(User.definition).unique(User.cols.email)` and `.exists(User.cols.id)` read the model's table with its typed columns; the model is fixed by `Rules.of`, so a column of another model does not compile. They make the same `UniqueRule`/`ExistsRule` as `Rules.unique('users', 'email')`.

### Upgrade notes

- `package:daravel` (and `package:daravel/validation.dart`) export `Field` and `ModelRules`. An application type of either name now needs a prefix or `hide`.
