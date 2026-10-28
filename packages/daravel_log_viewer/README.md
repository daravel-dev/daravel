<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_log_viewer

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_log_viewer/README.id.md)

A log viewer page for [Daravel](https://pub.dev/packages/daravel), served
by your application: the newest entries first, level and text filters,
stack traces, and new entries live over server-sent events. Files are read
from their end, so the last 50 entries of a 500 MB log come back in under
a millisecond.

```bash
dart pub add daravel_log_viewer
```

```dart
import 'package:daravel_log_viewer/daravel_log_viewer.dart';

Application createApp() => Application.configure(basePath: '.')
    .withLogViewer(middleware: ['auth', 'can:view-logs'])
    // ...
    .create();
// https://your-app/log-viewer
```

- Reads Daravel's daily JSON logs and Laravel's Monolog files
  (`laravel.log`), multi-line stack traces included.
- Pages back through a file of any size in constant memory; searches stop
  after a set amount of the file and offer to read on.
- Hides secrets (`password`, `token`, `authorization`, ...) in context and
  text; opens only `.log` files of its folder; a page with a nonce-based
  Content-Security-Policy and no external assets; 403 outside local until
  it is given middleware.
- Download and (opt-in) delete; a JSON API for tools.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/log-viewer.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by either.
