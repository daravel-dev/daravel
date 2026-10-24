<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_lints

AST lint rules for [Daravel](https://pub.dev/packages/daravel) applications,
run by `dartisan lint` and in tests (they are not an IDE analyzer plugin).

| Rule | Catches |
| :-- | :-- |
| `no_dart_mirrors` | `dart:mirrors`, which AOT binaries cannot use |
| `no_print_in_app` | `print` in `lib/app` (use `Log`, which redacts and adds request context) |
| `no_mutable_static_in_app` | mutable statics and globals shared by every request |
| `no_sql_string_interpolation` | SQL built with interpolation or concatenation instead of bindings |
| `registry_entry_missing` | migrations, jobs, policies, listeners or commands left out of `bootstrap/` |

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
