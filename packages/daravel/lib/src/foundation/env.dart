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
  Env._(this._values);

  /// Creates an [Env] from an in-memory map (tests, CLI).
  factory Env.fromMap(Map<String, String> values) => Env._(Map.of(values));

  final Map<String, String> _values;

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
    Future<void> loadLevel(String name, Map<String, String> context) async {
      final plain = File(p.join(basePath, name));
      if (await plain.exists()) {
        values.addAll(parse(await plain.readAsString(), context: context));
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
        values.addAll(parse(contents, context: {...values, ...context}));
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
    return Env._(values);
  }

  /// Parses dotenv [contents] (Laravel/dotenv compatible subset: comments,
  /// `export` prefix, single/double quotes, `\n`/`\t`/`\"`/`\\` escapes in
  /// double quotes, `${VAR}` expansion (a bare `$VAR` stays literal, as in phpdotenv) in unquoted and double quoted
  /// values, inline ` # comments` after unquoted values).
  static Map<String, String> parse(
    String contents, {
    Map<String, String> context = const {},
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
      values[key] = _parseValue(rawValue, values, context, startLine);
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
    int lineNumber,
  ) {
    if (raw.isEmpty) {
      return '';
    }
    if (raw.startsWith('"')) {
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
            case '"':
              buffer.write('"');
            case r'\':
              buffer.write(r'\');
            default:
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
        buffer.write(char);
        index++;
      }
      if (!closed) {
        throw EnvException(
          'Unterminated double quote on .env line $lineNumber.',
        );
      }
      return _expand(buffer.toString(), values, context);
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
    var value = raw;
    final commentIndex = value.indexOf(' #');
    if (commentIndex != -1) {
      value = value.substring(0, commentIndex).trimRight();
    }
    return _expand(value, values, context);
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
