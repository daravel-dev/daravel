import 'dart:convert';

/// One entry of a log file: a line of Daravel's JSON log, or a Monolog
/// entry of a Laravel log (`[2026-10-28 08:00:00] local.ERROR: ...` and
/// the stack trace lines after it).
final class LogEntry {
  const LogEntry({
    required this.offset,
    required this.length,
    required this.level,
    required this.message,
    this.time,
    this.channel,
    this.context,
    this.error,
    this.trace,
    required this.raw,
  });

  /// Where the entry starts in the file, in bytes.
  final int offset;

  /// Its length in bytes, line breaks included.
  final int length;

  /// `debug` to `emergency`; `unknown` for a line that is neither format.
  final String level;
  final String message;
  final String? time;
  final String? channel;
  final Object? context;
  final String? error;
  final String? trace;

  /// The entry as written.
  final String raw;

  Map<String, Object?> toJson() => {
    'offset': offset,
    'level': level,
    'time': time,
    'channel': channel,
    'message': message,
    'context': context,
    'error': error,
    'trace': trace,
  };

  /// [text] (one or more lines starting at [offset]) parsed as a JSON line
  /// or a Monolog entry; anything else is kept as an `unknown` entry.
  factory LogEntry.parse(String text, int offset, int length) {
    final trimmed = text.trimRight();
    if (trimmed.startsWith('{')) {
      try {
        if (jsonDecode(trimmed) case final Map<String, Object?> json) {
          return LogEntry(
            offset: offset,
            length: length,
            level: '${json['level'] ?? json['level_name'] ?? 'unknown'}'
                .toLowerCase(),
            message: '${json['message'] ?? ''}',
            time: (json['time'] ?? json['datetime'])?.toString(),
            channel: json['channel']?.toString(),
            context: json['context'],
            error: json['error']?.toString(),
            trace: json['trace']?.toString(),
            raw: trimmed,
          );
        }
      } on FormatException {
        // Not JSON after all: kept as text below.
      }
    }
    final header = monologHeader.firstMatch(trimmed);
    if (header != null) {
      final rest = trimmed.substring(header.end);
      final newline = rest.indexOf('\n');
      final first = newline < 0 ? rest : rest.substring(0, newline);
      final trace = newline < 0 ? null : rest.substring(newline + 1);
      return LogEntry(
        offset: offset,
        length: length,
        level: header[3]!.toLowerCase(),
        message: first,
        time: header[1],
        channel: header[2],
        trace: trace == null || trace.trim().isEmpty ? null : trace,
        raw: trimmed,
      );
    }
    return LogEntry(
      offset: offset,
      length: length,
      level: 'unknown',
      message: trimmed,
      raw: trimmed,
    );
  }

  /// The first line of a Monolog entry: `[time] channel.LEVEL: `.
  static final RegExp monologHeader = RegExp(
    r'^\[(\d{4}-\d{2}-\d{2}[T ][0-9:.]+(?:[+-]\d{2}:?\d{2}|Z)?)\] ([\w.-]+)\.([A-Za-z]+): ',
  );

  /// Whether [line] starts an entry (a JSON line or a Monolog header);
  /// other lines continue the entry above them.
  static bool startsEntry(String line) =>
      line.startsWith('{') || monologHeader.hasMatch(line);
}
