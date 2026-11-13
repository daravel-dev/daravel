import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../foundation/config.dart';
import 'context.dart';
import '../foundation/container.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';
import '../foundation/loggable.dart';

/// RFC 5424 levels (ordered by severity).
enum LogLevel {
  /// Detailed debugging information.
  debug,

  /// Interesting events.
  info,

  /// Normal but significant events.
  notice,

  /// Exceptional occurrences that are not errors.
  warning,

  /// Runtime errors that need no immediate action.
  error,

  /// Critical conditions.
  critical,

  /// Action must be taken immediately.
  alert,

  /// The system is unusable.
  emergency;

  /// Parses `LOG_LEVEL` values (`debug`, `warning`, `warn`, …).
  static LogLevel parse(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'warn') {
      return .warning;
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
  /// One log entry.
  const LogRecord({
    required this.time,
    required this.level,
    required this.message,
    required this.channel,
    this.context = const <String, Object?>{},
    this.error,
    this.stackTrace,
  });

  /// When it was logged.
  final DateTime time;

  /// How severe it is.
  final LogLevel level;

  /// The message.
  final String message;

  /// The channel it was logged on.
  final String channel;

  /// Shared + request + call context, already redacted.
  final Map<String, Object?> context;

  /// The error logged with it, if any.
  final Object? error;

  /// The error's stack trace, if any.
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
  /// Writes [record].
  void handle(LogRecord record);

  /// Flushes and closes the handler.
  Future<void> close();
}

String _encodeContext(Map<String, Object?> context) =>
    jsonEncode(context, toEncodable: (Object? value) => '$value');

/// Log lines waiting for one asynchronous writer, bounded in bytes.
///
/// [add] never blocks and never throws: once [maxPendingBytes] are waiting,
/// a line is dropped and counted ([dropped], [droppedTotal]), so a log
/// storm or a slow disk or pipe costs a bounded amount of memory instead of
/// growing the heap until the writes catch up. One loop writes the lines in
/// order, in batches of consecutive lines for the same target. A write that
/// fails drops its batch, counted the same way, and never surfaces as an
/// uncaught asynchronous error.
final class LogLineQueue {
  /// A queue writing batches with [write]; its second argument is the
  /// `target` the lines were added with (a file path, or null).
  LogLineQueue(
    this._write, {
    this.maxPendingBytes = defaultMaxPendingBytes,
    this.label = 'Log output',
  });

  /// Bytes a queue holds before it drops lines (8 MiB).
  static const int defaultMaxPendingBytes = 8 * 1024 * 1024;

  /// Lines a write takes at most at once.
  static const int _batchBytes = 64 * 1024;

  /// Lines dropped by every queue of this isolate
  /// (`log_lines_dropped_total`).
  static int get droppedTotal => _droppedTotal;
  static int _droppedTotal = 0;

  final Future<void> Function(Uint8List bytes, Object? target) _write;

  /// The most bytes waiting before lines are dropped.
  final int maxPendingBytes;

  /// Names the output in the notice written when lines start to drop.
  final String label;

  final ListQueue<(Uint8List, Object?)> _lines =
      ListQueue<(Uint8List, Object?)>();
  int _pendingBytes = 0;
  int _dropped = 0;
  bool _behind = false;
  bool _running = false;
  Completer<void>? _idle;

  /// Bytes added and not written yet.
  int get pendingBytes => _pendingBytes;

  /// Lines this queue dropped (full, or their write failed).
  int get dropped => _dropped;

  /// Whether nothing is being written.
  bool get isIdle => !_running;

  /// Queues [line] (a newline is appended) for [target].
  void add(String line, {Object? target}) {
    final bytes = utf8.encode('$line\n');
    if (_pendingBytes > 0 && _pendingBytes + bytes.length > maxPendingBytes) {
      _countDropped(1);
      if (!_behind) {
        _behind = true;
        _notice(
          '[daravel] $label is behind ($_pendingBytes bytes waiting): '
          'dropping log lines until it catches up.',
        );
      }
      return;
    }
    _lines.add((bytes, target));
    _pendingBytes += bytes.length;
    if (!_running) {
      _running = true;
      // In the root zone: the loop outlives the request that started it.
      unawaited(Zone.root.run(_drain));
    }
  }

  void _countDropped(int lines) {
    _dropped += lines;
    _droppedTotal += lines;
  }

  Future<void> _drain() async {
    try {
      while (_lines.isNotEmpty) {
        final target = _lines.first.$2;
        final batch = BytesBuilder(copy: false);
        var count = 0;
        while (_lines.isNotEmpty &&
            _lines.first.$2 == target &&
            batch.length < _batchBytes) {
          batch.add(_lines.removeFirst().$1);
          count++;
        }
        final bytes = batch.takeBytes();
        try {
          await _write(bytes, target);
        } catch (_) {
          // The writer reports its own failures; the lines are lost.
          _countDropped(count);
        } finally {
          _pendingBytes -= bytes.length;
        }
      }
      _behind = false;
    } finally {
      _running = false;
      final idle = _idle;
      _idle = null;
      idle?.complete();
    }
  }

  /// Completes once every line added so far is written (or dropped), or
  /// after [timeout].
  Future<void> flush([Duration? timeout]) async {
    if (!_running) {
      return;
    }
    final idle = (_idle ??= Completer<void>()).future;
    if (timeout == null) {
      await idle;
    } else {
      await idle.timeout(timeout, onTimeout: () {});
    }
  }
}

void _notice(String message) {
  try {
    stderr.writeln(message);
  } catch (_) {
    // Nowhere left to say it.
  }
}

/// The isolate's queues in front of stdout and stderr ([ConsoleHandler],
/// [JsonHandler]): written through `nonBlocking` sinks, so an undrained
/// pipe (a slow log collector) delays log lines instead of blocking the
/// event loop.
final Map<int, LogLineQueue> _stdQueues = <int, LogLineQueue>{};

LogLineQueue _stdQueue(bool error) => _stdQueues.putIfAbsent(error ? 2 : 1, () {
  // ignore: close_sinks (the process's stdout or stderr, never closed)
  final sink = (error ? stderr : stdout).nonBlocking;
  // A failed write also fails `done`; the queue already counted it.
  sink.done.ignore();
  return LogLineQueue((bytes, _) {
    sink.add(bytes);
    return sink.flush();
  }, label: error ? 'stderr' : 'stdout');
});

/// Where a handler writes lines: the given sink as before, synchronously;
/// otherwise the process's stdout or stderr through [_stdQueue]. Inside
/// `IOOverrides.runZoned` (a test capturing output, `dartisan mcp:serve`
/// moving logs to stderr) the zone's own sink is used as given.
void Function(String line) _lineWriter(
  StringSink? given, {
  required bool error,
}) {
  if (given != null) {
    return given.writeln;
  }
  if (IOOverrides.current != null) {
    return (error ? stderr : stdout).writeln;
  }
  return _stdQueue(error).add;
}

Future<void> _flushStd() async {
  for (final queue in _stdQueues.values) {
    await queue.flush(const Duration(seconds: 5));
  }
}

/// Human-readable lines; warnings and above go to [err].
///
/// Without [out] and [err] the lines go to stdout and stderr through a
/// bounded, non-blocking queue ([LogLineQueue]): logging never blocks the
/// event loop on a pipe nobody reads, and past 8 MiB waiting lines are
/// dropped and counted (`log_lines_dropped_total`). [close] waits (up to
/// 5 s) for the lines already queued.
final class ConsoleHandler implements LogHandler {
  /// Writes to stdout, errors to stderr; [showChannel] prefixes the
  /// channel.
  ConsoleHandler({StringSink? out, StringSink? err, this.showChannel = false})
    : _out = _lineWriter(out, error: false),
      _err = _lineWriter(err, error: true),
      _std = out == null || err == null;

  final void Function(String line) _out;
  final void Function(String line) _err;
  final bool _std;

  /// Whether each line starts with the channel.
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
    buffer.write(_escapeControls(record.message));
    if (record.context.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(_encodeContext(record.context));
    }
    if (record.error != null) {
      buffer
        ..write('\n  error: ')
        ..write(_escapeControls('${record.error}'));
    }
    if (record.stackTrace != null) {
      buffer
        ..write('\n')
        ..write(record.stackTrace);
    }
    final write = record.level.index >= LogLevel.warning.index ? _err : _out;
    write(buffer.toString());
  }

  @override
  Future<void> close() => _std ? _flushStd() : Future<void>.value();

  /// [text] with its control characters written as escapes (`\r`, `\n`,
  /// `\x1b`, ...; tab kept): a message or error that carries a line break
  /// (a route parameter, a header, a client's input) cannot forge a log
  /// line, and an ESC cannot drive the terminal. Monolog's `LineFormatter`,
  /// Laravel's default, likewise keeps an entry on one line. The stack
  /// trace stays on lines of its own.
  static String _escapeControls(String text) {
    if (!_controls.hasMatch(text)) {
      return text;
    }
    return text.replaceAllMapped(
      _controls,
      (m) => switch (m[0]!) {
        '\n' => r'\n',
        '\r' => r'\r',
        final c => '\\x${c.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}',
      },
    );
  }

  static final RegExp _controls = RegExp('[\\x00-\\x08\\x0a-\\x1f\\x7f]');
}

/// One JSON object per line (containers, log shippers).
///
/// Without [sink] the lines go to stdout through the same bounded,
/// non-blocking queue as [ConsoleHandler].
final class JsonHandler implements LogHandler {
  /// Writes one JSON object per line, to [sink] or stdout.
  JsonHandler([StringSink? sink])
    : _write = _lineWriter(sink, error: false),
      _std = sink == null;

  final void Function(String line) _write;
  final bool _std;

  @override
  void handle(LogRecord record) => _write(
    jsonEncode(record.toJson(), toEncodable: (Object? value) => '$value'),
  );

  @override
  Future<void> close() => _std ? _flushStd() : Future<void>.value();
}

/// `daravel-YYYY-MM-DD.log` files rotated daily, keeping [days] files.
///
/// [handle] only queues the line ([LogLineQueue]); one loop opens, writes
/// and rotates the files. When a file cannot be opened or written (a full
/// disk, a permission, a directory in its place) one notice goes to
/// stderr, the lines are dropped and counted, and the file is opened again
/// [retryAfter] later; the failure is never an uncaught error that could
/// take a worker down. At most [maxPendingBytes] wait in memory when the
/// disk is slower than the log rate. [close] waits up to [closeTimeout] for
/// the lines already queued.
final class DailyFileHandler implements LogHandler {
  /// Writes to one file per day in [directory], keeping [days] of them.
  DailyFileHandler(
    this.directory, {
    this.name = 'daravel',
    this.days = 14,
    int maxPendingBytes = LogLineQueue.defaultMaxPendingBytes,
    this.retryAfter = const Duration(seconds: 5),
    this.closeTimeout = const Duration(seconds: 10),
  }) {
    _queue = LogLineQueue(
      _writeTo,
      maxPendingBytes: maxPendingBytes,
      label: 'The log file in $directory',
    );
  }

  /// The directory of the log files.
  final String directory;

  /// The file name prefix.
  final String name;

  /// Files kept after rotation (`0` = keep all).
  final int days;

  /// How long after a failed open or write the file is tried again (lines
  /// logged meanwhile are dropped).
  final Duration retryAfter;

  /// How long [close] waits for queued lines.
  final Duration closeTimeout;

  late final LogLineQueue _queue;
  RandomAccessFile? _file;
  String? _currentDate;
  DateTime? _retryAt;
  bool _failing = false;

  /// Bytes logged and not on disk yet.
  int get pendingBytes => _queue.pendingBytes;

  /// Lines dropped: the queue was full, or the file could not be written.
  int get dropped => _queue.dropped;

  /// Completes once the lines logged so far are written (or dropped).
  Future<void> flush() => _queue.flush();

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
  void handle(LogRecord record) => _queue.add(
    jsonEncode(record.toJson(), toEncodable: (Object? value) => '$value'),
    target: pathFor(record.time),
  );

  /// Runs in the queue's loop only, one call at a time.
  Future<void> _writeTo(Uint8List bytes, Object? target) async {
    final path = target! as String;
    var file = _file;
    if (file == null || path != _currentDate) {
      final retryAt = _retryAt;
      if (retryAt != null && DateTime.now().isBefore(retryAt)) {
        throw StateError('The log file is unavailable.');
      }
      // The previous day's file is flushed and closed before the next opens.
      await _closeFile();
      try {
        await Directory(directory).create(recursive: true);
        file = await File(path).open(mode: FileMode.append);
      } catch (error) {
        _fail(path, error);
        rethrow;
      }
      _file = file;
      _currentDate = path;
      _retryAt = null;
      if (_failing) {
        _failing = false;
        _notice('[daravel] Writing log file $path again.');
      }
      _prune();
    }
    try {
      await file.writeFrom(bytes);
    } catch (error) {
      _fail(path, error);
      await _closeFile();
      rethrow;
    }
  }

  void _fail(String path, Object error) {
    _retryAt = DateTime.now().add(retryAfter);
    if (!_failing) {
      _failing = true;
      _notice(
        '[daravel] Cannot write log file $path: $error. Log lines are '
        'dropped; trying again every ${retryAfter.inSeconds}s.',
      );
    }
  }

  Future<void> _closeFile() async {
    final file = _file;
    _file = null;
    _currentDate = null;
    try {
      await file?.close();
    } catch (_) {
      // Already broken; nothing more to flush.
    }
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
    // The current file is never counted: keep it plus the `days - 1`
    // newest others.
    final current = _currentDate == null ? null : p.basename(_currentDate!);
    final files = dir.listSync().whereType<File>().where((f) {
      final base = p.basename(f.path);
      return pattern.hasMatch(base) && base != current;
    }).toList()..sort((a, b) => b.path.compareTo(a.path));
    for (final stale in files.skip(days - 1)) {
      try {
        stale.deleteSync();
      } on FileSystemException {
        // Locked or already gone: retried at the next rotation.
      }
    }
  }

  @override
  Future<void> close() async {
    await _queue.flush(closeTimeout);
    // Past the timeout a write is still running: the loop closes nothing
    // under it, and the file goes with the process.
    if (_queue.isIdle) {
      await _closeFile();
    }
  }
}

/// Keeps records in memory; returned by `Log.spy()` for assertions.
final class MemoryHandler implements LogHandler {
  /// The records logged, in order.
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

  /// Whether a record of [level] matching [pattern] was logged.
  bool hasLogged(LogLevel level, [Pattern? pattern]) =>
      matching(level, pattern).isNotEmpty;

  /// Fails unless a record of [level] matching [pattern] was logged.
  void assertLogged(LogLevel level, [Pattern? pattern]) {
    if (!hasLogged(level, pattern)) {
      throw StateError(
        'Expected a [${level.name}] log${pattern == null ? '' : ' matching "$pattern"'}; '
        'got ${records.map((r) => '[${r.level.name}] ${r.message}').join(' | ')}.',
      );
    }
  }

  /// Fails if a record of [level] matching [pattern] was logged.
  void assertNotLogged(LogLevel level, [Pattern? pattern]) {
    if (hasLogged(level, pattern)) {
      throw StateError('Unexpected [${level.name}] log matching "$pattern".');
    }
  }

  /// Forgets the records.
  void clear() => records.clear();
}

/// Per-scope (request/job/command) context added to every log line.
final class LogContext {
  /// A context of [values].
  LogContext([Map<String, Object?>? values])
    : values = <String, Object?>{...?values};

  /// The context entries.
  final Map<String, Object?> values;
}

/// `LOG_*` configuration (`config/logging.php`).
final class LoggingConfig implements ConfigSection {
  /// Logging settings; usually from `.env` (`LOG_*`).
  const LoggingConfig({
    this.channel = 'stack',
    this.stack = const <String>['console'],
    this.level = .debug,
    this.path = 'storage/logs',
    this.days = 14,
    this.redact = defaultRedactedKeys,
  });

  /// The settings in `LOG_*`.
  factory LoggingConfig.fromEnv(Env env) => LoggingConfig(
    channel: env.string('LOG_CHANNEL', 'stack'),
    stack: env.list('LOG_STACK', const <String>['console']),
    level: LogLevel.parse(env.string('LOG_LEVEL', 'debug')),
    path: env.string('LOG_PATH', 'storage/logs'),
    days: env.integer('LOG_DAILY_DAYS', 14),
    redact: env.list('LOG_REDACT', defaultRedactedKeys),
  );

  /// Context keys whose values are replaced by `[REDACTED]` (substring,
  /// whatever the case and `-`/`_`) — BLUEPRINT_V2 §7.6.5.
  static const List<String> defaultRedactedKeys = <String>[
    'password',
    'passwd',
    'pwd',
    'token',
    'authorization',
    'bearer',
    'cookie',
    'secret',
    'api_key',
    'apikey',
    'jwt',
    'session_id',
    'private_key',
    'credentials',
    'dsn',
  ];

  /// Default channel (`stack`, `console`, `json`, `daily`, `null`).
  final String channel;

  /// Channels combined by `stack`.
  final List<String> stack;

  /// The lowest level written (`LOG_LEVEL`).
  final LogLevel level;

  /// The directory of file logs (`LOG_PATH`).
  final String path;

  /// How many daily files are kept (`LOG_DAILY_DAYS`).
  final int days;

  /// Context keys whose values are replaced with `[redacted]`.
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
    this.minimumLevel = .debug,
    StringSink? out,
    StringSink? err,
    List<LogHandler>? handlers,
    this.channel = 'default',
    List<String> redact = LoggingConfig.defaultRedactedKeys,
  }) : _handlers = handlers == null
           ? <LogHandler>[ConsoleHandler(out: out, err: err)]
           : List<LogHandler>.of(handlers),
       _redact = redact.map(_normalizeKey).toList();

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

  /// The handlers records go to.
  List<LogHandler> get handlers => List<LogHandler>.unmodifiable(_handlers);

  /// Adds [handler].
  void addHandler(LogHandler handler) => _handlers.add(handler);

  /// Removes [handler]; returns whether it was there.
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

  /// The context added to every record of this logger.
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

  /// Logs [message] at debug level.
  void debug(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.debug, message, context: context);

  /// Logs [message] at info level.
  void info(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.info, message, context: context);

  /// Logs [message] at notice level.
  void notice(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.notice, message, context: context);

  /// Logs [message] at warning level.
  void warning(String message, [Map<String, Object?>? context]) =>
      log(LogLevel.warning, message, context: context);

  /// Logs [message] at error level, with the error and stack trace.
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

  /// Logs [message] at critical level, with the error and stack trace.
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
    final merged = <String, Object?>{
      ..._shared,
      ...Context.forLogging,
      ...scopeContext,
      ...?context,
    };
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

  /// Replaces values of sensitive keys (recursively) with `[REDACTED]`:
  /// in every map whatever its key type (keys written with `toString`), in
  /// every list, set and other iterable, and in a [Loggable] such as
  /// `Headers`. Keys match whatever their case and `-` or `_`
  /// (`X-Api-Key` matches `api_key`). Nesting past 32 levels is cut.
  Map<String, Object?> redact(Map<String, Object?> context) =>
      _redactMap(context, 0);

  Map<String, Object?> _redactMap(Map<Object?, Object?> map, int depth) => {
    for (final MapEntry(:key, :value) in map.entries)
      '$key': _isSensitive('$key')
          ? '[REDACTED]'
          : _redactValue(value, depth + 1),
  };

  Object? _redactValue(Object? value, int depth) {
    if (depth > _maxDepth) {
      return '[DEPTH]';
    }
    return switch (value) {
      Loggable() => _redactValue(value.toLogValue(), depth + 1),
      Map<Object?, Object?>() => _redactMap(value, depth),
      // Bytes stay as they are (not a structure that holds keys).
      Uint8List() => value,
      Iterable<Object?>() => [
        for (final v in value) _redactValue(v, depth + 1),
      ],
      _ => value,
    };
  }

  static const int _maxDepth = 32;

  bool _isSensitive(String key) {
    final normalized = _normalizeKey(key);
    return _redact.any(normalized.contains);
  }

  /// Lower case without `-` and `_`, so `X-API-KEY`, `api_key` and `apiKey`
  /// are one name.
  static String _normalizeKey(String key) =>
      key.toLowerCase().replaceAll('-', '').replaceAll('_', '');

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
