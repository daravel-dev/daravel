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

These run only when a project enables them, under `diagnostics:` in its
`analysis_options.yaml`, read by `dartisan lint` and by `expectLintClean()`
from `daravel_test` (the editor plugin reads the `plugins:` form):

```yaml
daravel_lints:              # or plugins: daravel_lints_plugin:, with the plugin
  diagnostics:
    prefer_sql_identifier: true   # an opt-in rule on
    no_print_in_app: false        # a default rule off
```

When the project enables the plugin, its `plugins: daravel_lints_plugin:
diagnostics:` block is the one read (a `daravel_lints:` block next to it
is ignored, with a warning). As in the analyzer, a severity (`info`,
`warning`, `error`) or a list of names also turns a rule on; write
`false`, not `ignore`, to turn one off (the analysis server reads
`ignore` there as on, so `dartisan lint` refuses it). Only the project's
own file is read:
`include:` is not followed, and in a pub workspace the file is the one of
the package `dartisan` runs in. `dartisan lint --enable=<rule>` and
`--disable=<rule>` change one run, and its summary line names the opt-in
rules it ran. In code: `lintProject(root, rules: lintConfig(root).rules)`.

| Rule | Catches |
| :-- | :-- |
| `prefer_sql_identifier` | a column name passed to a query builder method (`where`, `orderBy`, `select`, `pluck`, ...) that is neither a string literal, a `const`, a choice between literals (`sort == 'name' ? 'name' : 'id'`) nor a `SqlIdentifier` |
| `string_validation_rule` | a string rule list (`'required\|email\|max:255'`) where a `Rules` chain means the same (`Rules.required().email().max(255)`), which the editor completes and the compiler checks; the message names the chain. Not reported where no exact chain exists (`regex`, an unknown rule, a non-numeric `min`) |
| `string_column_name` | a column name written as a string in a model query (`User.query().where('email', x)`, `User.where(...)`) where the model's `cols` record holds that column, in a method that takes a typed column (`where`, `orWhere`, `orderBy`, `latest`, `pluck`, `select`, `count`, ...): the message names the token (`User.cols.email`). The rule reads the project's `lib/app/models` (`StringColumnName.forProject(root)`, which `LintConfig.rulesIn(root)` builds once the rule is enabled, in `dartisan lint` and `expectLintClean()`; the editor plugin reads only the models each file refers to, under `lib/app/models` of its package, and rereads a model when it changes). Its fix writes the token (`(removes const)` when it drops the `const` of a `select([...])` list; not in a list typed `<String>`); `whereIn`, `whereNull` and the like take a `String` and are left alone |

`SqlIdentifier('users.id')` checks a name once, where it is made (plain
names joined by dots, else an `ArgumentError`), and the builder quotes it
as it quotes the same string. A list of allowed columns is still the
better check for a name that comes from a request: `SqlIdentifier` only
keeps odd characters out, any existing column still passes.

`string_validation_rule` also writes the chain for you:
`rule.fixFor(unit, node)` returns a `LintFix` (a message such as
`Write as Rules.required().email()` and its text edits), which the editor
plugin offers as a quick fix, for one finding or all in the file. The fix
is offered only where the chain compiles and means the same:
- one plain string literal (not interpolated, not adjacent strings);
- not in a list or map typed to hold strings, by its own type arguments
  (`<String>[...]`, `<String, String>{...}`) or by the declaration it
  initializes or returns from (a variable or field typed
  `Map<String, String>`, a method, getter or function declared to return
  one, such as a `rules()` override);
- in a `const` context only when removing the `const` of the enclosing
  list or map is enough, never in a `const` variable or a `const`
  constructor call. The message then ends in `(removes const)`: the other
  elements lose their constant context too, so `[Foo(), 'required']` makes
  a new `Foo` each time;
- not when the file's import of `package:daravel/daravel.dart` hides
  `Rules`. The import's prefix is used, and the import is added when
  missing.

Without resolution, the rule cannot see a type that reaches the literal
from elsewhere, such as a map passed to your own function's parameter
typed `Map<String, String>`. There the fix can produce code that does not
compile, and the editor shows the error at once.

`rule.fixesIn(unit)` returns every fix in a file, and `LintFixMerger`
combines them, making an edit two fixes share only once. `string_column_name`
also offers a fix (see the table); the other rules offer none
(`LintRule.fixFor` explains why for each). `fixSource(source, path,
rules: ...)` applies every fix in a file, leaving the findings
`// daravel-lint-ignore:` silences alone, as `dartisan lint --fix` does.

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
