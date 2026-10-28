import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown for a file name the viewer refuses (a path, a hidden file, not a
/// `.log`): answered with 404, as if the file did not exist.
final class LogFileRefused implements Exception {
  const LogFileRefused(this.name);
  final String name;
  @override
  String toString() => 'LogFileRefused: $name';
}

/// Lets the viewer open only `.log` files directly inside its folder.
final class PathGuard {
  PathGuard(this.directory);

  final String directory;

  static final RegExp _name = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,200}\.log$',
  );

  /// Whether [name] may name a log file (no separators, no `..`, no NUL,
  /// not hidden, ends with `.log`).
  static bool validName(String name) =>
      _name.hasMatch(name) && !name.contains('..');

  /// The file [name] in the folder, or [LogFileRefused]. A symbolic link
  /// pointing outside the folder is refused too.
  File resolve(String name) {
    if (!validName(name)) {
      throw LogFileRefused(name);
    }
    final root = Directory(directory);
    if (!root.existsSync()) {
      throw LogFileRefused(name);
    }
    final file = File(p.join(directory, name));
    if (!file.existsSync()) {
      throw LogFileRefused(name);
    }
    final real = p.canonicalize(file.resolveSymbolicLinksSync());
    final realRoot = p.canonicalize(root.resolveSymbolicLinksSync());
    if (p.dirname(real) != realRoot) {
      throw LogFileRefused(name);
    }
    return file;
  }

  /// The log files of the folder, newest first.
  List<File> files() {
    final root = Directory(directory);
    if (!root.existsSync()) {
      return const [];
    }
    final files = [
      for (final entity in root.listSync(followLinks: false))
        if (entity is File && validName(p.basename(entity.path))) entity,
    ];
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }
}

/// Hides the values of sensitive keys before an entry reaches the page.
final class Masker {
  Masker(List<String> keys)
    : _keys = [
        for (final key in keys)
          if (key.trim().isNotEmpty) key.trim().toLowerCase(),
      ],
      _text = keys.where((k) => k.trim().isNotEmpty).isEmpty
          ? null
          : RegExp(
              '(["\']?)([A-Za-z0-9_.-]*(?:${keys.where((k) => k.trim().isNotEmpty).map((k) => RegExp.escape(k.trim())).join('|')})[A-Za-z0-9_.-]*)\\1(\\s*[:=]\\s*)("(?:[^"\\\\]|\\\\.)*"|\'[^\']*\'|[^\\s,;&}\\]]+)',
              caseSensitive: false,
            );

  static const String mask = '********';

  final List<String> _keys;
  final RegExp? _text;

  bool _sensitive(String key) {
    final lower = key.toLowerCase();
    return _keys.any(lower.contains);
  }

  /// [value] with the values of sensitive keys replaced, at any depth.
  Object? json(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, value: inner) in map.entries)
        '$key': _sensitive('$key') ? mask : json(inner),
    },
    final List<Object?> list => [for (final item in list) json(item)],
    final String text => this.text(text),
    _ => value,
  };

  /// `password=x`, `"token": "y"` and `api_key: z` in [text] with their
  /// values replaced.
  String text(String text) {
    final pattern = _text;
    if (pattern == null) {
      return text;
    }
    return text.replaceAllMapped(pattern, (m) {
      final value = m[4]!;
      final quote = value.startsWith('"') || value.startsWith("'")
          ? value[0]
          : '';
      return '${m[1]}${m[2]}${m[1]}${m[3]}$quote$mask$quote';
    });
  }
}
