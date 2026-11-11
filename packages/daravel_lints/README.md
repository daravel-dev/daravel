<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_lints

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_lints/README.id.md)

AST lint rules for [Daravel](https://pub.dev/packages/daravel) applications,
run by `dartisan lint` and in tests (they are not an IDE analyzer plugin).

| Rule | Catches |
| :-- | :-- |
| `no_dart_mirrors` | `dart:mirrors`, which AOT binaries cannot use |
| `no_print_in_app` | `print` in `lib/app` (use `Log`, which redacts and adds request context) |
| `no_mutable_static_in_app` | mutable statics and globals shared by every request |
| `no_sql_string_interpolation` | SQL built with interpolation or concatenation instead of bindings |
| `invalid_validation_rule` | unknown validation rules and missing arguments (`max` without a value) |
| `unawaited_in_db_transaction` | a query inside `DB.transaction` that is not awaited |
| `invalid_timezone` | a time zone name the scheduler does not know |
| `no_inline_js_interpolation` | a value interpolated into an inline `on*=` handler of generated HTML, where HTML escaping does not stop a quote from ending the JavaScript string (use a `data-*` attribute and `addEventListener`) |
| `registry_entry_missing` | migrations, jobs, policies, listeners or commands left out of `bootstrap/` |

### Opt-in rules

These run only when a project enables them, in an architecture test
(`expectLintClean(null, ['prefer_sql_identifier'])` from `daravel_test`) or
through `lintProject(root, rules: rulesWith(['prefer_sql_identifier']))`.
`dartisan lint` runs the default rules only.

| Rule | Catches |
| :-- | :-- |
| `prefer_sql_identifier` | a column name passed to a query builder method (`where`, `orderBy`, `select`, `pluck`, ...) that is neither a string literal, a `const`, a choice between literals (`sort == 'name' ? 'name' : 'id'`) nor a `SqlIdentifier` |
| `string_validation_rule` | a string rule list (`'required\|email\|max:255'`) where a `Rules` chain means the same (`Rules.required().email().max(255)`), which the editor completes and the compiler checks; the message names the chain. Not reported where no exact chain exists (`regex`, an unknown rule, a non-numeric `min`) |
| `string_column_name` | a column name written as a string in a model query (`User.query().where('email', x)`, `User.where(...)`) where the model's `cols` record holds that column, in a method that takes a typed column (`where`, `orWhere`, `orderBy`, `latest`, `pluck`, `select`, `count`, ...): the message names the token (`User.cols.email`). The rule reads the project's `lib/app/models` (`StringColumnName.forProject(root)`); `whereIn`, `whereNull` and the like take a `String` and are left alone |

`SqlIdentifier('users.id')` checks a name once, where it is made (plain
names joined by dots, else an `ArgumentError`), and the builder quotes it
as it quotes the same string. A list of allowed columns is still the
better check for a name that comes from a request: `SqlIdentifier` only
keeps odd characters out, any existing column still passes.

Suppress a finding with `// daravel-lint-ignore: <rule>` on the same line or the
line above.

```dart
import 'package:daravel_lints/daravel_lints.dart';

final issues = lintSource(source, 'lib/app/http/controllers/search.dart');
```

See [`example/main.dart`](example/main.dart).

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by either.
