import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../foundation/config.dart';
import '../foundation/container.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';

/// RFC 5424 levels (ordered by severity).
enum LogLevel {
  debug,
  info,
  notice,
  warning,
  error,
  critical,
  alert,
  emergency;

  /// Parses `LOG_LEVEL` values (`debug`, `warning`, `warn`, …).
  static LogLevel parse(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'warn') {
      return LogLevel.warning;
    }
    return LogLevel.values.firstWhere(
      (l) => l.name == normalized,
      orElse: () => throw ConfigException(
        'LOG_LEVEL must be one of ${LogLevel.values.map((l) => l.name).join(', ')}; '
        'got [$value].',
      ),
    );
  }
}

/// One log entry as handed to [LogHandler]s.
final class LogRecord {
  const LogRecord({
    required this.time,
    required this.level,
    required this.message,
    required this.channel,
    this.context = const <String, Object?>{},
    this.error,
    this.stackTrace,
  });

  final DateTime time;
  final LogLevel level;
  final String message;
  final String channel;

  /// Shared + request + call context, already redacted.
  final Map<String, Object?> context;
  final Object? error;
  final StackTrace? stackTrace;

  /// Plain-JSON form used by the JSON and file handlers.
  Map<String, Object?> toJson() => <String, Object?>{
    'time': time.toIso8601String(),
    'level': level.name,
    'channel': channel,
    'message': message,
    if (context.isNotEmpty) 'context': context,
    if (error != null) 'error': '$error',
    if (stackTrace != null) 'trace': '$stackTrace',
  };
}

/// Destination of log records (console, JSON stdout, daily file, memory…).
abstract interface class LogHandler {
  void handle(LogRecord record);

  Future<void> close();
}

String _encodeContext(Map<String, Object?> context) =>
    jsonEncode(context, toEncodable: (Object? value) => '$value');

/// Human-readable lines; warnings and above go to [err].
final class ConsoleHandler implements LogHandler {
  ConsoleHandler({StringSink? out, StringSink? err, this.showChannel = false})
    : _out = out ?? stdout,
      _err = err ?? stderr;

  final StringSink _out;
  final StringSink _err;
  final bool showChannel;

  @override
  void handle(LogRecord record) {
    final buffer = StringBuffer()
      ..write(record.time.toIso8601String())
      ..write(' [')
      ..write(record.level.name.toUpperCase())
      ..write('] ');
    if (showChannel) {
      buffer.write('${record.channel}: ');
    }
    buffer.write(record.message);
    if (record.context.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(_encodeContext(record.context));
    }
    if (record.error != null) {
      buffer
        ..write('\n  error: ')
        ..write(record.error);
    }
    if (record.stackTrace != null) {
      buffer
        ..write('\n')
        ..write(record.stackTrace);
    }
    final sink = record.level.index >= LogLevel.warning.index ? _err : _out;
    sink.writeln(buffer);
  }

  @override
  Future<void> close() async {}
}

/// One JSON object per line (containers, log shippers).
final class JsonHandler implements LogHandler {
  JsonHandler([StringSink? sink]) : _sink = sink ?? stdout;

  final StringSink _sink;

  @override
  void handle(LogRecord record) => _sink.writeln(
    jsonEncode(record.toJson(), toEncodable: (Object? value) => '$value'),
  );

  @override
  Future<void> close() async {}
}

/// `daravel-YYYY-MM-DD.log` files rotated daily, keeping [days] files.
final class DailyFileHandler implements LogHandler {
  DailyFileHandler(this.directory, {this.name = 'daravel', this.days = 14});

  final String directory;
  final String name;

  /// Files kept after rotation (`0` = keep all).
  final int days;

  IOSink? _sink;
  String? _currentDate;

  /// Path of the file written for [date].
  String pathFor(DateTime date) {
    final d = date.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return p.join(
      directory,
      '$name-${d.year}-${two(d.month)}-${two(d.day)}.log',
    );
  }

  @override
  void handle(LogRecord record) {
    final date = pathFor(record.time);
    if (date != _currentDate) {
      _sink?.close().ignore();
      _sink = null;
      Directory(directory).createSync(recursive: true);
      _sink = File(date).openWrite(mode: FileMode.append);
      _currentDate = date;
      _prune();
    }
    _sink!.writeln(
      jsonEncode(record.toJson(), toEncodable: (Object? value) => '$value'),
    );
  }

  void _prune() {
    if (days <= 0) {
      return;
    }
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      return;
    }
    final pattern = RegExp(
      '^${RegExp.escape(name)}-\\d{4}-\\d{2}-\\d{2}\\.log\$',
    );
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => pattern.hasMatch(p.basename(f.path)))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final stale in files.skip(days)) {
      try {
        stale.deleteSync();
      } on FileSystemException {
        // Locked or already gone: retried at the next rotation.
      }
    }
  }

  @override
  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    _currentDate = null;
    await sink?.flush();
    await sink?.close();
  }
}

/// Keeps records in memory; returned by `Log.spy()` for assertions.
final class MemoryHandler implements LogHandler {
  final List<LogRecord> records = <LogRecord>[];

  @override
  void handle(LogRecord record) => records.add(record);

  @override
  Future<void> close() async {}

  /// Records at [level] whose message contains [pattern] (string or RegExp).
  List<LogRecord> matching(LogLevel level, [Pattern? pattern]) => [
    for (final r in records)
      if (r.level == level && (pattern == null || r.message.contains(pattern)))
        r,
  ];

  bool hasLogged(LogLevel level, [Pattern? pattern]) =>
      matching(level, pattern).isNotEmpty;

  void assertLogged(LogLevel level, [Pattern? pattern]) {
    if (!hasLogged(level, pattern)) {
      throw StateError(
        'Expected a [${level.name}] log${pattern == null ? '' : ' matching "$pattern"'}; '
        'got ${records.map((r) => '[${r.level.name}] ${r.message}').join(' | ')}.',
      );
    }
  }

  void assertNotLogged(LogLevel level, [Pattern? pattern]) {
    if (hasLogged(level, pattern)) {
      throw StateError('Unexpected [${level.name}] log matching "$pattern".');
    }
  }

  void clear() => records.clear();
}

/// Per-scope (request/job/command) context added to every log line.
final class LogContext {
  LogContext([Map<String, Object?>? values])
    : values = <String, Object?>{...?values};

  final Map<String, Object?> values;
}

/// `LOG_*` configuration (`config/logging.php`).
final class LoggingConfig implements ConfigSection {
  const LoggingConfig({
    this.channel = 'stack',
    this.stack = const <String>['console'],
    this.level = LogLevel.debug,
    this.path = 'storage/logs',
    this.days = 14,
    this.redact = defaultRedactedKeys,
  });

  factory LoggingConfig.fromEnv(Env env) => LoggingConfig(
    channel: env.string('LOG_CHANNEL', 'stack'),
    stack: env.list('LOG_STACK', const <String>['console']),
    level: LogLevel.parse(env.string('LOG_LEVEL', 'debug')),
    path: env.string('LOG_PATH', 'storage/logs'),
    days: env.integer('LOG_DAILY_DAYS', 14),
    redact: env.list('LOG_REDACT', defaultRedactedKeys),
  );

  /// Context keys whose values are replaced by `[REDACTED]` (substring,
  /// case-insensitive) — BLUEPRINT_V2 §7.6.5.
  static const List<String> defaultRedactedKeys = <String>[
    'password',
    'token',
    'authorization',
    'cookie',
    'secret',
    'api_key',
  ];

  /// Default channel (`stack`, `console`, `json`, `daily`, `null`).
  final String channel;

  /// Channels combined by `stack`.
  final List<String> stack;
  final LogLevel level;
  final String path;
  final int days;
  final List<String> redact;

  @override
  String get key => 'logging';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'default': channel,
    'level': level.name,
    'channels': {
      'stack': {'driver': 'stack', 'channels': stack},
      'console': {'driver': 'console'},
      'json': {'driver': 'json'},
      'daily': {'driver': 'daily', 'path': path, 'days': days},
      'null': {'driver': 'null'},
    },
  };
}

/// Structured logger with channels, scope context and redaction
/// (BLUEPRINT_V2 §7.10.3).
final class Logger {
  /// Console logger; pass [handlers] to replace the console output.
  Logger({
    this.minimumLevel = LogLevel.debug,
    StringSink? out,
    StringSink? err,
    List<LogHandler>? handlers,
    this.channel = 'default',
    List<String> redact = LoggingConfig.defaultRedactedKeys,
  }) : _handlers = handlers == null
           ? <LogHandler>[ConsoleHandler(out: out, err: err)]
           : List<LogHandler>.of(handlers),
       _redact = redact.map((k) => k.toLowerCase()).toList();

  /// Builds the default channel and every named channel from [config].
  factory Logger.fromConfig(
    LoggingConfig config, {
    required String basePath,
    LogLevel? minimumLevel,
  }) {
    final level = minimumLevel ?? config.level;
    final directory = p.isAbsolute(config.path)
        ? config.path
        : p.join(basePath, config.path);
    List<LogHandler> handlersFor(String name, Set<String> seen) {
      if (!seen.add(name)) {
        throw ConfigException('Log stack [$name] references itself.');
      }
      return switch (name) {
        'console' => <LogHandler>[ConsoleHandler()],
        'json' => <LogHandler>[JsonHandler()],
        'daily' => <LogHandler>[DailyFileHandler(directory, days: config.days)],
        'null' => <LogHandler>[],
        'stack' => <LogHandler>[
          for (final child in config.stack) ...handlersFor(child, seen),
        ],
        _ => throw ConfigException(
          'Unknown log channel [$name] (console, json, daily, stack, null).',
        ),
      };
    }

    final root = Logger(
      minimumLevel: level,
      handlers: handlersFor(config.channel, <String>{}),
      channel: config.channel,
      redact: config.redact,
    );
    for (final name in const <String>['console', 'json', 'daily', 'null']) {
      if (name != config.channel) {
        root._channels[name] = () => Logger(
          minimumLevel: level,
          handlers: handlersFor(name, <String>{}),
          channel: name,
          redact: config.redact,
        ).._shared = root._shared;
      }
    }
    return root;
  }

  /// Messages below this level are dropped.
  final LogLevel minimumLevel;

  /// Channel name stamped on every record.
  final String channel;

  final List<LogHandler> _handlers;
  final List<String> _redact;
  Map<String, Object?> _shared = <String, Object?>{};
  final Map<String, Logger Function()> _channels = {};
  final Map<String, Logger> _resolved = <String, Logger>{};

  List<LogHandler> get handlers => List<LogHandler>.unmodifiable(_handlers);

  void addHandler(LogHandler handler) => _handlers.add(handler);

  bool removeHandler(LogHandler handler) => _handlers.remove(handler);

  /// Registers (or replaces) a named channel.
  void registerChannel(String name, Logger logger) {
    logger._shared = _shared;
    _resolved[name] = logger;
  }

  /// A named channel (`Log::channel('daily')`); [channel] itself returns
  /// this logger.
  Logger channelNamed(String name) {
    if (name == channel) {
      return this;
    }
    final existing = _resolved[name];
    if (existing != null) {
      return existing;
    }
    final factory = _channels[name];
    if (factory == null) {
      throw ConfigException('Log channel [$name] is not defined.');
    }
    return _resolved[name] = factory();
  }

  /// Context added to every record of every channel (`Log::shareContext`).
  void shareContext(Map<String, Object?> context) => _shared.addAll(context);

  Map<String, Object?> get sharedContext => Map.unmodifiable(_shared);

  /// Adds context to the current request/job scope, or shares it when no
  /// scope is active (`Log::withContext`).
  void withContext(Map<String, Object?> context) {
    final scope = _scope();
    if (scope == null) {
      shareContext(context);
      return;
    }
    (scope.get<LogContext>() ??
            (scope..put<LogContext>(LogContext())).get<LogContext>()!)
        .values
        .addAll(context);
  }

  /// Context of the current scope (empty outside a scope).
  Map<String, Object?> get scopeContext =>
      _scope()?.get<LogContext>()?.values ?? const <String, Object?>{};

  void debug(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.debug, message, context: context);

  void info(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.info, message, context: context);

  void notice(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.notice, message, context: context);

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

  void critical(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) => log(
    LogLevel.critical,
    message,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  /// Writes one record to every handler.
  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) {
    if (level.index < minimumLevel.index || _handlers.isEmpty) {
      return;
    }
    final merged = <String, Object?>{..._shared, ...scopeContext, ...?context};
    final record = LogRecord(
      time: DateTime.now().toUtc(),
      level: level,
      message: message,
      channel: channel,
      context: merged.isEmpty ? const <String, Object?>{} : redact(merged),
      error: error,
      stackTrace: stackTrace,
    );
    for (final handler in _handlers) {
      try {
        handler.handle(record);
      } catch (e) {
        stderr.writeln(
          '[daravel] Log handler ${handler.runtimeType} failed: $e',
        );
      }
    }
  }

  /// Replaces values of sensitive keys (recursively) with `[REDACTED]`.
  Map<String, Object?> redact(Map<String, Object?> context) => {
    for (final entry in context.entries)
      entry.key: _isSensitive(entry.key)
          ? '[REDACTED]'
          : _redactValue(entry.value),
  };

  Object? _redactValue(Object? value) => switch (value) {
    Map<String, Object?>() => redact(value),
    List<Object?>() => [for (final v in value) _redactValue(v)],
    _ => value,
  };

  bool _isSensitive(String key) {
    final lower = key.toLowerCase();
    return _redact.any(lower.contains);
  }

  /// Flushes and closes every handler of this logger and its channels.
  Future<void> close() async {
    for (final handler in _handlers) {
      await handler.close();
    }
    for (final logger in _resolved.values) {
      await logger.close();
    }
  }

  static Scope? _scope() {
    try {
      return Container.current.currentScope;
    } on StateError {
      return null;
    }
  }
}
