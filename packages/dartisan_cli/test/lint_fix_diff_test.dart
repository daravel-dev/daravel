import 'dart:io';
import 'dart:math';

import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The diff `dartisan lint --fix --dry-run` prints (#360): Myers' shortest
/// edit script, checked against random edits and a plain LCS.
void main() {
  /// The number of lines kept by a longest common subsequence (small
  /// inputs only: a table of a.length × b.length).
  int lcs(List<String> a, List<String> b) {
    final t = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        t[i][j] = a[i] == b[j]
            ? t[i + 1][j + 1] + 1
            : max(t[i + 1][j], t[i][j + 1]);
      }
    }
    return t[0][0];
  }

  test('rebuilds both sides and keeps as many lines as an LCS', () {
    final random = Random(330);
    for (var round = 0; round < 500; round++) {
      final a = [
        for (var i = 0; i < random.nextInt(30); i++) 'l${random.nextInt(6)}',
      ];
      final b = [...a];
      for (var e = 0; e < random.nextInt(6); e++) {
        final at = b.isEmpty ? 0 : random.nextInt(b.length + 1);
        switch (random.nextInt(3)) {
          case 0:
            b.insert(at, 'n${random.nextInt(6)}');
          case 1 when at < b.length:
            b.removeAt(at);
          case _ when at < b.length:
            b[at] = 'c${random.nextInt(6)}';
        }
      }
      final edits = lineEdits(a, b);
      expect(
        [
          for (final (op, line) in edits)
            if (op != '+') line,
        ],
        a,
        reason: 'round $round',
      );
      expect(
        [
          for (final (op, line) in edits)
            if (op != '-') line,
        ],
        b,
        reason: 'round $round',
      );
      expect(
        edits.where((e) => e.$1 == ' ').length,
        lcs(a, b),
        reason: 'round $round: shortest',
      );
    }
  });

  test('the printed hunks: line numbers, removals before additions', () {
    expect(
      lintFixDiff('a.dart', 'a\nb\nc\nd', 'a\nB\nc\nd\ne'),
      '--- a.dart\n+++ a.dart\n@@ 2 @@\n-b\n+B\n@@ 5 @@\n+e\n',
    );
    expect(lintFixDiff('a.dart', 'x', 'x'), '--- a.dart\n+++ a.dart\n');
  });

  group('countAnalyzeErrors', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('count_errors');
      File(p.join(root.path, 'lib', 'a.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x\n');
    });
    tearDown(() => root.deleteSync(recursive: true));

    /// One `--format=machine` error line for [file].
    String error(String file) {
      final escaped = file.replaceAll(r'\', r'\\');
      return 'ERROR|COMPILE_TIME_ERROR|X|$escaped|1|1|1|bad';
    }

    String real(String relative) =>
        File(p.join(root.path, relative)).resolveSymbolicLinksSync();

    test('counts the real path dart analyze writes', () {
      expect(
        countAnalyzeErrors(error(real('lib/a.dart')), root.path, [
          'lib/a.dart',
        ]),
        {'lib/a.dart': 1},
      );
    });

    test('an error in a file it was not asked about: no verdict', () {
      expect(
        countAnalyzeErrors(error(real('lib/a.dart')), root.path, [
          'lib/b.dart',
        ]),
        isNull,
      );
    });

    test('a root reached through a link counts the same', () {
      final link = Link('${root.path}_link');
      try {
        link.createSync(root.path);
      } on FileSystemException {
        markTestSkipped('cannot make links here');
        return;
      }
      addTearDown(link.deleteSync);
      expect(
        countAnalyzeErrors(error(real('lib/a.dart')), link.path, [
          'lib/a.dart',
        ]),
        {'lib/a.dart': 1},
      );
    });

    test('Windows: a short 8.3 root and another case count the same', () {
      // `cmd` prints the 8.3 name of the folder, as GitHub's runner has
      // it (`C:\Users\RUNNER~1\...`); the same path when the volume has
      // no short names. (No quotes around the path: Dart's own quoting of
      // the argument would reach `for` as part of the name; the temporary
      // folder has no spaces.)
      expect(root.path, isNot(contains(' ')));
      final short = Process.runSync('cmd', [
        '/c',
        'for %I in (${root.path}) do @echo %~sI',
      ]).stdout.toString().trim();
      expect(Directory(short).existsSync(), isTrue, reason: short);
      for (final base in [short, root.path.toUpperCase()]) {
        expect(
          countAnalyzeErrors(error(real('lib/a.dart')), base, ['lib/a.dart']),
          {'lib/a.dart': 1},
          reason: base,
        );
      }
    }, skip: Platform.isWindows ? false : 'Windows paths');
  });

  test('machine output fields are unescaped', () {
    expect(machineFields(r'ERROR|T|C|C:\\Users\\a.dart|3|1|7|a \| b'), [
      'ERROR',
      'T',
      'C',
      r'C:\Users\a.dart',
      '3',
      '1',
      '7',
      'a | b',
    ]);
    expect(machineFields('plain'), ['plain']);
  });

  test('two fixes far apart in a long file stay cheap', () {
    // A table of N × M cells took 3.9 GB and 16 s for 20 000 lines.
    final before = [for (var i = 0; i < 20000; i++) 'line $i'];
    final after = [...before]
      ..[0] = 'fixed 0'
      ..[19999] = 'fixed 19999';
    final watch = Stopwatch()..start();
    final diff = lintFixDiff('a.dart', before.join('\n'), after.join('\n'));
    expect(watch.elapsedMilliseconds, lessThan(1000));
    expect(diff, contains('@@ 1 @@\n-line 0\n+fixed 0\n'));
    expect(diff, contains('@@ 20000 @@\n-line 19999\n+fixed 19999\n'));
  });
}
