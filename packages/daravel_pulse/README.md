<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_pulse

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_pulse/README.id.md)

A dashboard for [Daravel](https://pub.dev/packages/daravel) after Laravel
Pulse, served by your application: requests and their latency, slow
requests and queries, exceptions, queues and jobs, merged across every
worker isolate, with no database of its own and no external service.

```bash
dart pub add daravel_pulse
```

```dart
import 'package:daravel_pulse/daravel_pulse.dart';

Application createApp() => Application.configure(basePath: '.')
    .withPulse(middleware: ['auth', 'can:viewPulse'])
    // ...
    .create();
// https://your-app/pulse
```

- Requests by minute (count, server errors, average time) over 1, 6 or 24
  hours; slow requests by route pattern, never the raw path.
- Slow queries by SQL, without their bindings; exceptions by class and the
  first frame in your code, with the latest trace.
- Queue sizes, the `failed_jobs` of the period, slow and failed jobs.
- Each isolate records in bounded memory; under a supervisor the workers
  send their reports to the coordinator, so the page shows the whole
  process.
- Laravel Pulse's threshold keys (`PULSE_SLOW_QUERIES_THRESHOLD`, ...); a
  page with a nonce-based Content-Security-Policy and no external assets;
  403 outside local until it is given middleware.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/pulse.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by either.
