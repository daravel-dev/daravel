/// What `dartisan env:sync` writes into `lib/config/env_keys.dart`: one
/// `EnvKey<T>` per variable of `.env.example`, with the comments above it
/// as its documentation (wave 9, W9.7).
///
/// Only `.env.example` is read, never `.env`: the keys and their types come
/// from the file every checkout has, and a local secret never reaches the
/// generated code. Even from `.env.example` a value is copied into the
/// documentation only when it cannot be a credential.
library;

import 'region_format.dart';

/// One variable of `.env.example`.
typedef EnvVariable = ({
  String key,
  String value,
  String type,
  bool commentedOut,
  List<String> doc,
});

const String _start = '// <dartisan:env>';
const String _end = '// </dartisan:env>';

final RegExp _keyLine = RegExp(
  r'^(#\s*)?(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=(.*)$',
);
final RegExp _typeLine = RegExp(r'^#\s*@type\s+(String|int|bool)\s*$');

/// The variables of [example] (the text of `.env.example`), in order. A
/// comment block right above a variable is its documentation (a blank line
/// ends a block); `# @type String` above a variable sets its type instead
/// of the one its value suggests; `# KEY=value` is a variable commented out
/// (optional). A key seen twice keeps its first line.
List<EnvVariable> parseEnvExample(String example) {
  final out = <EnvVariable>[];
  final seen = <String>{};
  var doc = <String>[];
  String? type;
  for (final raw in example.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) {
      doc = [];
      type = null;
      continue;
    }
    final typed = _typeLine.firstMatch(line);
    if (typed != null) {
      type = typed.group(1);
      continue;
    }
    final match = _keyLine.firstMatch(line);
    if (match != null) {
      final key = match.group(2)!;
      if (seen.add(key)) {
        final value = _value(match.group(3)!);
        out.add((
          key: key,
          value: value,
          type: type ?? _typeOf(value),
          commentedOut: match.group(1) != null,
          doc: doc,
        ));
      }
      doc = [];
      type = null;
      continue;
    }
    if (line.startsWith('#')) {
      doc = [...doc, line.replaceFirst(RegExp(r'^#+\s?'), '')];
    }
  }
  return out;
}

String _value(String raw) {
  var value = raw.trim();
  if (value.length >= 2 &&
      (value.startsWith('"') && value.endsWith('"') ||
          value.startsWith("'") && value.endsWith("'"))) {
    return value.substring(1, value.length - 1);
  }
  // An unquoted value ends at an inline comment.
  final comment = value.indexOf(' #');
  if (comment != -1) {
    value = value.substring(0, comment).trimRight();
  }
  return value;
}

String _typeOf(String value) {
  if (RegExp(r'^-?\d+$').hasMatch(value)) {
    return 'int';
  }
  if (const {'true', 'false'}.contains(value.toLowerCase())) {
    return 'bool';
  }
  return 'String';
}

/// Words in a key name that mark a value that may be a credential.
const List<String> secretWords = [
  'KEY',
  'SECRET',
  'PASSWORD',
  'PASS',
  'TOKEN',
  'DSN',
  'URL',
  'CREDENTIAL',
  'PRIVATE',
];

/// Whether the example value of [variable] may be copied into the
/// documentation: an `int` or `bool`, or a short string (at most 40
/// characters) without `://` or `@` whose key names no [secretWords].
/// `.env.example` files often hold real credentials (`DB_URL`,
/// `REDIS_URL`), so anything else is left out.
bool mayCopyValue(EnvVariable variable) {
  if (variable.type == 'int' || variable.type == 'bool') {
    return true;
  }
  final value = variable.value;
  final words = variable.key.split('_');
  return value.length <= 40 &&
      !value.contains('://') &&
      !value.contains('@') &&
      !words.any(secretWords.contains);
}

String _fieldName(String key, Set<String> taken) {
  final words = key.toLowerCase().split('_').where((w) => w.isNotEmpty);
  var name = [
    for (final (i, w) in words.indexed)
      i == 0 ? w : w[0].toUpperCase() + w.substring(1),
  ].join();
  if (name.isEmpty || RegExp('^[0-9]').hasMatch(name)) {
    name = 'v$name';
  }
  var candidate = name;
  for (var i = 2; !taken.add(candidate); i++) {
    candidate = '$name$i';
  }
  return candidate;
}

/// The `<dartisan:env>` region for [variables].
String envRegion(List<EnvVariable> variables) {
  final out = StringBuffer()
    ..writeln(_start)
    ..writeln(
      '/// The variables of `.env.example` (written by `dartisan env:sync`; '
      'edit `.env.example`, not this).',
    )
    ..writeln('abstract final class EnvKeys {');
  final taken = <String>{};
  for (final v in variables) {
    for (final line in v.doc) {
      out.writeln('  /// $line'.trimRight());
    }
    if (v.doc.isNotEmpty) {
      out.writeln('  ///');
    }
    final example = v.value.isEmpty
        ? 'Empty in `.env.example`'
        : mayCopyValue(v)
        ? 'Example in `.env.example`: `${v.value.replaceAll('`', "'")}`'
        : 'Set in `.env.example` (value not copied)';
    out
      ..writeln(
        '  /// $example${v.commentedOut ? ' (commented out: optional)' : ''}.',
      )
      ..writeln(
        '  static const ${_fieldName(v.key, taken)} = '
        "EnvKey<${v.type}${v.commentedOut ? '?' : ''}>('${v.key}');",
      );
  }
  out
    ..writeln('}')
    ..write(_end);
  return out.toString();
}

/// [source] (the current `lib/config/env_keys.dart`, or null) with its
/// region written for [example] and laid out by [formatter].
({String source, String? warning}) syncEnvSource(
  String? source,
  String example, {
  RegionFormatter? formatter,
}) {
  var code = envRegion(parseEnvExample(example));
  String? warning;
  if (formatter != null) {
    final body = code.substring(_start.length, code.length - _end.length);
    final formatted = formatter.topLevel(body.trim());
    if (formatter.lastFailure == null) {
      code = '$_start\n$formatted\n$_end';
    } else {
      warning =
          'The env region could not be formatted (${formatter.lastFailure}); '
          'written as generated.';
    }
  }
  final base = source ?? "import 'package:daravel/daravel.dart';\n";
  final start = base.indexOf(_start);
  final end = base.indexOf(_end);
  if (start != -1 && end > start) {
    return (
      source:
          '${base.substring(0, start)}$code'
          '${base.substring(end + _end.length)}',
      warning: warning,
    );
  }
  final head = base.endsWith('\n') ? base : '$base\n';
  return (source: '$head\n$code\n', warning: warning);
}
