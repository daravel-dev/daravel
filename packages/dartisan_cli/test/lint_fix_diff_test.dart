import 'dart:math';

import 'package:dartisan_cli/dartisan_cli.dart';
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
