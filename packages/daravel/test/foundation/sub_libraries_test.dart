import 'dart:io';

import 'package:test/test.dart';

/// `package:daravel/foundation.dart`, `http.dart`, `database.dart`,
/// `auth.dart` and `validation.dart` are subsets of the full barrel: every
/// export they make is one of `daravel.dart`'s, so importing a subset never
/// gives a name the full barrel does not, and nothing is exported twice.
void main() {
  final lib = Directory('lib');
  final barrel = _exports(File('lib/daravel.dart'));

  for (final name in ['foundation', 'http', 'database', 'auth', 'validation']) {
    test('$name.dart exports a subset of daravel.dart', () {
      final exports = _exports(File('${lib.path}/$name.dart'));
      expect(exports, isNotEmpty);
      expect(exports.toSet().length, exports.length, reason: 'duplicates');
      for (final line in exports) {
        expect(barrel, contains(line), reason: '$name.dart: $line');
      }
    });
  }

  test('the five subsets cover the barrel\'s main areas', () {
    final covered = {
      for (final name in [
        'foundation',
        'http',
        'database',
        'auth',
        'validation',
      ])
        ..._exports(File('${lib.path}/$name.dart')),
    };
    for (final area in [
      'foundation/',
      'http/',
      'database/',
      'auth/',
      'validation/',
      'routing/',
    ]) {
      final lines = barrel.where((l) => l.contains("'src/$area"));
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(covered, contains(line), reason: line);
      }
    }
  });
}

List<String> _exports(File file) => [
  for (final line in file.readAsLinesSync())
    if (line.startsWith('export ')) line.trim(),
];
