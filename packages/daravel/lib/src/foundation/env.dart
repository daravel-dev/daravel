import 'dart:io';

import 'package:path/path.dart' as p;

import 'exceptions.dart';

/// Decrypts the contents of an encrypted environment file with [key]
/// (`EnvironmentEncrypter.decrypt` in the application).
typedef EnvDecrypter = Future<String> Function(String contents, String key);

/// Typed access to environment variables loaded from `.env` files, the OS
/// environment and explicit overrides (BLUEPRINT_V2 §7.1.3).
///
/// Precedence (highest first): explicit overrides → OS environment → `.env`.
final class Env {
  Env._(this._values, [this.commentChanges = const []]);

  /// Creates an [Env] from an in-memory map (tests, CLI).
  factory Env.fromMap(Map<String, String> values) => Env._(Map.of(values));

  final Map<String, String> _values;

  /// The lines of the loaded files whose unquoted value Daravel 1.27 read
  /// differently: a `#` without a space before it now starts a comment, as
  /// in phpdotenv (`DB_PASSWORD=abc#123` is `abc`). Reported at boot by
  /// `ConfigValidator` with the file, the key and the line, never the
  /// value; this notice is removed after the 1.28 series.
  final List<EnvCommentChange> commentChanges;

  static final RegExp _keyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  // phpdotenv 5 (Laravel) resolves only `${NAME}`; a bare `$` is literal.
  static final RegExp _expansionPattern = RegExp(r'\$\{([a-zA-Z0-9_.]+)\}');

  /// Loads `[basePath]/[fileName]` when it exists, then the environment
  /// specific overlay `[fileName].{APP_ENV}` (e.g. `.env.testing`), then the
  /// OS environment (when [includePlatform]) and finally [overrides].
  ///
  /// `APP_ENV` for the overlay is taken from [overrides], the OS environment
  /// and the base file, in that order of precedence.
  ///
  /// Encrypted files (`.env.encrypted`, `.env.{APP_ENV}.encrypted`, written
  /// by `dartisan env:encrypt` or `php artisan env:encrypt`) are decrypted in
  /// memory with [decrypt] when one of [encryptionKeyVariables] is set, and
  /// override the plain file of the same level. Nothing is written to disk.
  static Future<Env> load({
    required String basePath,
    Map<String, String> overrides = const {},
    String fileName = '.env',
    bool includePlatform = true,
    EnvDecrypter? decrypt,
    List<String> encryptionKeyVariables = const [
      'DARAVEL_ENV_ENCRYPTION_KEY',
      'LARAVEL_ENV_ENCRYPTION_KEY',
    ],
  }) async {
    final platform = includePlatform
        ? Platform.environment
        : const <String, String>{};
    String? found;
    for (final name in encryptionKeyVariables) {
      found ??= overrides[name] ?? platform[name];
    }
    final key = found;
    final values = <String, String>{};
    final changes = <EnvCommentChange>[];
    Future<void> loadLevel(String name, Map<String, String> context) async {
      final plain = File(p.join(basePath, name));
      if (await plain.exists()) {
        values.addAll(
          parse(
            await plain.readAsString(),
            context: context,
            onCommentChange: (k, line) =>
                changes.add(EnvCommentChange(name, k, line)),
          ),
        );
      }
      final encrypted = File(p.join(basePath, '$name.encrypted'));
      if (decrypt != null &&
          key != null &&
          key.isNotEmpty &&
          await encrypted.exists()) {
        final String contents;
        try {
          contents = await decrypt(await encrypted.readAsString(), key);
        } catch (error) {
          throw EnvException(
            'Could not decrypt $name.encrypted with the configured key: '
            '$error',
          );
        }
        values.addAll(
          parse(
            contents,
            context: {...values, ...context},
            onCommentChange: (k, line) =>
                changes.add(EnvCommentChange('$name.encrypted', k, line)),
          ),
        );
      }
    }

    await loadLevel(fileName, platform);
    final appEnv =
        overrides['APP_ENV'] ?? platform['APP_ENV'] ?? values['APP_ENV'];
    if (appEnv != null && appEnv.isNotEmpty) {
      await loadLevel('$fileName.$appEnv', {...values, ...platform});
    }
    values.addAll(platform);
    values.addAll(overrides);
    return Env._(values, List.unmodifiable(changes));
  }

  /// Parses dotenv [contents] as phpdotenv 5.8 (Laravel) reads them:
  /// comments, the `export` prefix, single quotes (literal), double quotes
  /// (escapes and `${VAR}` expansion, see [_parseValue]), unquoted values
  /// (`${VAR}` expanded, a bare `$VAR` literal) that end at the first `#`.
  ///
  /// Where phpdotenv refuses a line Daravel is lenient: an unknown escape in
  /// double quotes stays as written, and an unquoted value may hold spaces.
  ///
  /// [onCommentChange] is told the key and line of each unquoted value that
  /// Daravel 1.27 read differently (it ended at ` #` only); [onLenient] the
  /// key and line of each value phpdotenv refuses and Daravel reads.
  static Map<String, String> parse(
    String contents, {
    Map<String, String> context = const {},
    void Function(String key, int line)? onCommentChange,
    void Function(String key, int line)? onLenient,
  }) {
    final values = <String, String>{};
    final lines = contents.split('\n');
    for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
      var line = lines[lineNumber].trimRight();
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      var statement = trimmed;
      if (statement.startsWith('export ')) {
        statement = statement.substring('export '.length).trim();
      }
      final separator = statement.indexOf('=');
      if (separator <= 0) {
        throw EnvException(
          'Invalid .env line ${lineNumber + 1}: expected KEY=VALUE.',
        );
      }
      final key = statement.substring(0, separator).trim();
      if (!_keyPattern.hasMatch(key)) {
        throw EnvException(
          'Invalid .env key "$key" on line ${lineNumber + 1}.',
        );
      }
      var rawValue = statement.substring(separator + 1).trim();
      final startLine = lineNumber + 1;
      // A double-quoted value may span lines, as in phpdotenv (PEM keys).
      if (rawValue.startsWith('"') && !_closesQuote(rawValue, 1)) {
        while (lineNumber + 1 < lines.length) {
          lineNumber++;
          var next = lines[lineNumber];
          if (next.endsWith('\r')) {
            next = next.substring(0, next.length - 1);
          }
          rawValue = '$rawValue\n$next';
          if (_closesQuote(next, 0)) {
            break;
          }
        }
      }
      if (onCommentChange != null &&
          !rawValue.startsWith('"') &&
          !rawValue.startsWith("'") &&
          _beforeComment(rawValue) != _beforeSpacedComment(rawValue)) {
        onCommentChange(key, startLine);
      }
      values[key] = _parseValue(
        rawValue,
        values,
        context,
        startLine,
        onLenient == null ? null : () => onLenient(key, startLine),
      );
    }
    return values;
  }

  /// Whether [text] has an unescaped `"` at or after [from].
  static bool _closesQuote(String text, int from) {
    for (var i = from; i < text.length; i++) {
      if (text[i] == r'\') {
        i++;
      } else if (text[i] == '"') {
        return true;
      }
    }
    return false;
  }

  static String _parseValue(
    String raw,
    Map<String, String> values,
    Map<String, String> context,
    int lineNumber, [
    void Function()? onLenient,
  ]) {
    if (raw.isEmpty) {
      return '';
    }
    if (raw.startsWith('"')) {
      // As phpdotenv 5.8 (`EntryParser::processToken`): `\"`, `\\` and
      // `\$` stand for the character itself, `\$` never starting a
      // reference; `\f`, `\n`, `\r`, `\t` and `\v` are decoded; a
      // `${NAME}` is expanded where it is read, so an escaped `$` is not.
      // Any other escape stays as written (phpdotenv refuses it).
      final buffer = StringBuffer();
      var index = 1;
      var closed = false;
      while (index < raw.length) {
        final char = raw[index];
        if (char == r'\' && index + 1 < raw.length) {
          final next = raw[index + 1];
          switch (next) {
            case 'n':
              buffer.write('\n');
            case 't':
              buffer.write('\t');
            case 'r':
              buffer.write('\r');
            case 'f':
              buffer.writeCharCode(12);
            case 'v':
              buffer.writeCharCode(11);
            case '"' || r'\' || r'$':
              buffer.write(next);
            default:
              // phpdotenv refuses it: kept as written.
              onLenient?.call();
              buffer
                ..write(r'\')
                ..write(next);
          }
          index += 2;
          continue;
        }
        if (char == '"') {
          closed = true;
          break;
        }
        if (char == r'$') {
          final reference = _expansionPattern.matchAsPrefix(raw, index);
          if (reference != null) {
            final name = reference.group(1)!;
            // Unknown references stay as written, as in phpdotenv.
            buffer.write(values[name] ?? context[name] ?? reference.group(0));
            index = reference.end;
            continue;
          }
        }
        buffer.write(char);
        index++;
      }
      if (!closed) {
        throw EnvException(
          'Unterminated double quote on .env line $lineNumber.',
        );
      }
      return buffer.toString();
    }
    if (raw.startsWith("'")) {
      final end = raw.indexOf("'", 1);
      if (end == -1) {
        throw EnvException(
          'Unterminated single quote on .env line $lineNumber.',
        );
      }
      return raw.substring(1, end);
    }
    final value = _beforeComment(raw);
    if (onLenient != null && value.contains(RegExp(r'\s'))) {
      // phpdotenv refuses whitespace in an unquoted value: kept.
      onLenient();
    }
    return _expand(value, values, context);
  }

  /// An unquoted [raw] value up to its first `#`, as phpdotenv's
  /// `UNQUOTED_STATE` reads it (a `#` starts a comment, a space before it
  /// or not).
  static String _beforeComment(String raw) {
    final hash = raw.indexOf('#');
    return hash < 0 ? raw : raw.substring(0, hash).trimRight();
  }

  /// [raw] as Daravel 1.27 read it: up to ` #` only. For
  /// [commentChanges]; removed after the 1.28 series.
  static String _beforeSpacedComment(String raw) {
    final hash = raw.indexOf(' #');
    return hash < 0 ? raw : raw.substring(0, hash).trimRight();
  }

  static String _expand(
    String value,
    Map<String, String> values,
    Map<String, String> context,
  ) => value.replaceAllMapped(_expansionPattern, (match) {
    final name = match.group(1)!;
    // Unknown references stay as written, as in phpdotenv.
    return values[name] ?? context[name] ?? match.group(0)!;
  });

  // ---------------------------------------------------------------------------
  // Typed accessors
  // ---------------------------------------------------------------------------

  /// Whether [key] is defined (possibly with an empty value).
  bool has(String key) => _values.containsKey(key);

  /// The raw value of [key], or `null`.
  String? maybeString(String key) => _values[key];

  /// The value of [key], or [fallback]; throws [EnvException] if neither
  /// exists.
  String string(String key, [String? fallback]) {
    final value = _values[key] ?? fallback;
    if (value == null) {
      throw EnvException('Environment variable [$key] is not set.');
    }
    return value;
  }

  /// Same as [string] but without a fallback (always required).
  String requireString(String key) => string(key);

  /// Parses [key] as an integer, or returns [fallback]. Throws when the value
  /// is present but not an integer.
  int integer(String key, [int? fallback]) {
    final raw = _values[key];
    if (raw == null || raw.isEmpty) {
      if (fallback == null) {
        throw EnvException('Environment variable [$key] is not set.');
      }
      return fallback;
    }
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      throw EnvException(
        'Environment variable [$key] must be an integer, got "$raw".',
      );
    }
    return parsed;
  }

  /// Parses [key] as a boolean (`true/false/1/0/yes/no/on/off`, case
  /// insensitive), or returns [fallback].
  bool boolean(String key, [bool fallback = false]) {
    final raw = _values[key];
    if (raw == null || raw.isEmpty) {
      return fallback;
    }
    switch (raw.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
      case 'on':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'off':
      case 'null':
      case '':
        return false;
      default:
        throw EnvException(
          'Environment variable [$key] must be a boolean, got "$raw".',
        );
    }
  }

  /// Splits [key] on commas (trimming entries), or returns [fallback].
  List<String> list(String key, [List<String> fallback = const []]) {
    final raw = _values[key];
    if (raw == null || raw.trim().isEmpty) {
      return fallback;
    }
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static final RegExp _durationPattern = RegExp(r'^(\d+)\s*(ms|s|m|h|d)?$');

  /// Parses [key] as a duration: `500ms`, `30s`, `5m`, `2h`, `1d`, or a bare
  /// number of seconds. Returns [fallback] when unset.
  Duration duration(String key, [Duration? fallback]) {
    final raw = _values[key];
    if (raw == null || raw.trim().isEmpty) {
      if (fallback == null) {
        throw EnvException('Environment variable [$key] is not set.');
      }
      return fallback;
    }
    final match = _durationPattern.firstMatch(raw.trim());
    if (match == null) {
      throw EnvException(
        'Environment variable [$key] must be a duration like 30s, 5m, 1h '
        'or 500ms, got "$raw".',
      );
    }
    final amount = int.parse(match.group(1)!);
    return switch (match.group(2)) {
      'ms' => Duration(milliseconds: amount),
      'm' => Duration(minutes: amount),
      'h' => Duration(hours: amount),
      'd' => Duration(days: amount),
      _ => Duration(seconds: amount),
    };
  }

  /// Matches [key] against the `name` of [values] (case-insensitive).
  E enumValue<E extends Enum>(String key, List<E> values, [E? fallback]) {
    final raw = _values[key];
    if (raw == null || raw.trim().isEmpty) {
      if (fallback == null) {
        throw EnvException('Environment variable [$key] is not set.');
      }
      return fallback;
    }
    final wanted = raw.trim().toLowerCase();
    for (final value in values) {
      if (value.name.toLowerCase() == wanted) {
        return value;
      }
    }
    throw EnvException(
      'Environment variable [$key] must be one of '
      '${values.map((v) => v.name).join(', ')}, got "$raw".',
    );
  }

  /// Parses [key] as an absolute URL, or returns [fallback].
  Uri url(String key, [Uri? fallback]) {
    final raw = _values[key];
    if (raw == null || raw.trim().isEmpty) {
      if (fallback == null) {
        throw EnvException('Environment variable [$key] is not set.');
      }
      return fallback;
    }
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      throw EnvException(
        'Environment variable [$key] must be an absolute URL, got "$raw".',
      );
    }
    return parsed;
  }

  /// An unmodifiable snapshot of all values.
  Map<String, String> toMap() => Map.unmodifiable(_values);
}

/// A line of a `.env` file whose unquoted value Daravel 1.27 read
/// differently ([Env.commentChanges]): the file, the key and the line,
/// never the value.
final class EnvCommentChange {
  /// The line [line] of [file], setting [key].
  const EnvCommentChange(this.file, this.key, this.line);

  /// The file name (`.env`, `.env.production`, `.env.encrypted`).
  final String file;

  /// The variable the line sets.
  final String key;

  /// The line number in [file] (in the decrypted contents of an
  /// encrypted file).
  final int line;
}
