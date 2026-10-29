/// Daravel Pulse (Blueprint #32): a dashboard served by the application
/// that shows what it is doing — requests, slow requests and queries,
/// exceptions, queues and jobs — merged across its worker isolates, with
/// no external service.
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withPulse(middleware: ['auth', 'can:viewPulse'])
/// ```
library;

export 'src/config.dart';
export 'src/pulse.dart';
export 'src/recorder.dart';
