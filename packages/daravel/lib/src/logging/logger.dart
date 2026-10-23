import 'dart:convert';
import 'dart:io';

/// RFC 5424 inspired log levels (subset used by Tier 0).
enum LogLevel { debug, info, warning, error }

/// Minimal structured console logger. Later slices add channels, JSON output,
/// per-request context via zones and redaction (BLUEPRINT_V2 §7.10.3).
final class Logger {
  Logger({this.minimumLevel = LogLevel.debug, StringSink? out, StringSink? err})
    : _out = out ?? stdout,
      _err = err ?? stderr;

  /// Messages below this level are dropped.
  final LogLevel minimumLevel;

  final StringSink _out;
  final StringSink _err;

  void debug(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.debug, message, context: context);

  void info(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.info, message, context: context);

  void warning(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.warning, message, context: context);

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => log(
    LogLevel.error,
    message,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  /// Writes a single log line (plus error/stack trace lines when given).
  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) {
    if (level.index < minimumLevel.index) {
      return;
    }
    final buffer = StringBuffer()
      ..write(DateTime.now().toUtc().toIso8601String())
      ..write(' [')
      ..write(level.name.toUpperCase())
      ..write('] ')
      ..write(message);
    if (context != null && context.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(jsonEncode(context, toEncodable: (Object? value) => '$value'));
    }
    if (error != null) {
      buffer
        ..write('\n  error: ')
        ..write(error);
    }
    if (stackTrace != null) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }
    final sink = level.index >= LogLevel.warning.index ? _err : _out;
    sink.writeln(buffer);
  }
}
