/// A log viewer for Daravel (Blueprint #53): a page served by the
/// application that reads its log files from their end, filters them,
/// follows them live over server-sent events, and hides secrets.
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withLogViewer(middleware: ['auth', 'can:view-logs'])
/// ```
library;

export 'src/config.dart';
export 'src/entry.dart';
export 'src/reader.dart';
export 'src/security.dart';
export 'src/viewer.dart';
