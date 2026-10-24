import 'dart:convert';

import 'encryption.dart';

/// Laravel-compatible encrypted environment files (`.env.encrypted`), as
/// written by `php artisan env:encrypt` and `dartisan env:encrypt`.
///
/// Two formats exist, both readable by either framework:
///
/// - the default: the whole file, PHP-serialized (`s:<bytes>:"...";`) and
///   encrypted as one `Crypt` payload;
/// - `--readable`: one `NAME=<payload>` line per variable, so the names stay
///   visible in diffs.
final class EnvironmentEncrypter {
  EnvironmentEncrypter(String key, {EncryptionCipher cipher = .aes256cbc})
    : _encrypter = Encrypter(parseKey(key), cipher: cipher);

  final Encrypter _encrypter;

  /// Environment variables that hold the key, in order of precedence.
  static const List<String> keyVariables = [
    'DARAVEL_ENV_ENCRYPTION_KEY',
    'LARAVEL_ENV_ENCRYPTION_KEY',
  ];

  /// Laravel's key parsing: `base64:<key>` is decoded, anything else is
  /// used as raw bytes (32 characters for AES-256).
  static List<int> parseKey(String key) =>
      key.startsWith('base64:') ? Encrypter.parseKey(key) : utf8.encode(key);

  /// Encrypts the contents of an environment file.
  Future<String> encrypt(String contents, {bool readable = false}) async {
    if (!readable) {
      return _encrypter.encryptString(_phpSerialize(contents));
    }
    final buffer = StringBuffer();
    for (final entry in _entries(contents)) {
      final separator = entry.indexOf('=');
      if (separator == -1) {
        continue;
      }
      final value = await _encrypter.encryptString(
        entry.substring(separator + 1),
      );
      buffer.writeln('${entry.substring(0, separator)}=$value');
    }
    return buffer.toString();
  }

  /// Decrypts either format back to dotenv text.
  ///
  /// Throws [DecryptException] when the key is wrong or the file is damaged.
  Future<String> decrypt(String encrypted) async {
    final contents = encrypted.trim();
    if (appearsEncrypted(contents)) {
      return _phpUnserialize(await _encrypter.decryptString(contents));
    }
    final buffer = StringBuffer();
    for (final entry in _entries(encrypted)) {
      final separator = entry.indexOf('=');
      if (separator == -1) {
        continue;
      }
      final value = await _encrypter.decryptString(
        entry.substring(separator + 1).trim(),
      );
      buffer.writeln('${entry.substring(0, separator)}=$value');
    }
    return buffer.toString();
  }

  /// Whether [value] is a single `Crypt` payload (Laravel's
  /// `Encrypter::appearsEncrypted`).
  static bool appearsEncrypted(String value) {
    try {
      final decoded = jsonDecode(utf8.decode(base64.decode(value.trim())));
      return decoded is Map<String, Object?> &&
          decoded['iv'] is String &&
          decoded['value'] is String &&
          decoded['mac'] is String;
    } on FormatException {
      return false;
    }
  }

  static String _phpSerialize(String value) =>
      's:${utf8.encode(value).length}:"$value";';

  /// Reverses PHP's `serialize()` of a string; anything else (a payload
  /// written by a tool that encrypted the raw text) is returned unchanged.
  static String _phpUnserialize(String value) {
    final match = RegExp(r'^s:(\d+):"').firstMatch(value);
    if (match == null) {
      return value;
    }
    final length = int.parse(match.group(1)!);
    final bytes = utf8.encode(value.substring(match.end));
    if (bytes.length != length + 2 ||
        utf8.decode(bytes.sublist(length)) != '";') {
      throw const DecryptException('The encrypted environment is invalid.');
    }
    return utf8.decode(bytes.sublist(0, length));
  }

  /// Non-empty, non-comment entries of a dotenv file, with quoted values
  /// that span several lines joined (phpdotenv's `Lines::process`).
  static List<String> _entries(String contents) {
    final entries = <String>[];
    String? open;
    for (final line in contents.split(RegExp(r'\r\n|\r|\n'))) {
      if (open != null) {
        open = '$open\n$line';
        if (_quoteCount(line).isOdd) {
          entries.add(open);
          open = null;
        }
        continue;
      }
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final separator = line.indexOf('=');
      final value = separator == -1 ? '' : line.substring(separator + 1);
      final opensQuote =
          value.trimLeft().startsWith('"') && _quoteCount(value).isOdd;
      if (opensQuote) {
        open = line;
      } else {
        entries.add(line);
      }
    }
    if (open != null) {
      entries.add(open);
    }
    return entries;
  }

  static int _quoteCount(String value) =>
      RegExp(r'(?<!\\)"').allMatches(value).length;
}
