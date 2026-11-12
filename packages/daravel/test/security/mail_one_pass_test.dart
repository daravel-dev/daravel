@Tags(['security'])
library;

import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/foundation/regexp_chars.dart';
import 'package:daravel/src/mail/one_pass.dart';
import 'package:test/test.dart';

import 'mail_golden.dart';

/// Mail markdown and addresses are read in one pass. The regular
/// expressions replaced scanned to the end of the text from every opener
/// without its closer: a 64 KiB body took up to 80 s in [markdownToText],
/// which runs for every markdown mail, and `a` + 64 KiB of spaces + `b`
/// took 57 s in [MailAddress.parse].
void main() {
  group('the same results as the regular expressions', () {
    test(r'\s, line terminators and \w: every UTF-16 code unit', () {
      final space = RegExp(r'^\s$');
      final any = RegExp(r'^.$');
      final word = RegExp(r'^\w$');
      for (var c = 0; c <= 0xFFFF; c++) {
        final char = String.fromCharCode(c);
        expect(isRegExpSpace(c), space.hasMatch(char), reason: '$c');
        expect(isLineTerminator(c), !any.hasMatch(char), reason: '$c');
        expect(isRegExpWord(c), word.hasMatch(char), reason: '$c');
      }
    });

    const fragments = [
      '<x-mail::button',
      '<x-mail::button url="u" color="success">',
      '</x-mail::button>',
      '<x-mail::panel>',
      '</x-mail::panel>',
      '<a ',
      'href="',
      'url="',
      'curl="',
      '"',
      '>',
      '<',
      '[',
      ']',
      '(',
      ')',
      '<br>',
      '<br />',
      '\n',
      ' ',
      '\t',
      'x',
      'A',
      '_',
      '-',
      'buttonx',
      '&lt;',
      '@',
      'a@b.test',
      '</a>',
      '<>',
      // So that links and anchors match often (13 000 and 2 300 of the
      // 100 000 values, some several times), not almost never.
      '](',
      '[x](u)',
      '<a href="h">',
      '<a x href="h" y>',
    ];
    final random = Random(20261113);
    String value(int parts) => [
      for (var n = random.nextInt(parts + 1); n > 0; n--)
        fragments[random.nextInt(fragments.length)],
    ].join();

    String pair(Match m) => '{${m[1]}|${m[2]}}';

    for (final (label, expected, actual)
        in <(String, String Function(String), String Function(String))>[
          (
            'replaceButtonTags',
            (t) => t.replaceAllMapped(
              RegExp(
                r'<x-mail::button\b([^>]*)>(.*?)</x-mail::button>',
                dotAll: true,
              ),
              pair,
            ),
            (t) => replaceButtonTags(t, (a, b) => '{$a|$b}'),
          ),
          (
            'replacePanelTags',
            (t) => t.replaceAllMapped(
              RegExp(r'<x-mail::panel>(.*?)</x-mail::panel>', dotAll: true),
              (m) => '{${m[1]}}',
            ),
            (t) => replacePanelTags(t, (a) => '{$a}'),
          ),
          (
            'replaceAttributeTags, buttons',
            (t) => t.replaceAllMapped(
              RegExp(
                r'<x-mail::button\b[^>]*url="([^"]*)"[^>]*>(.*?)</x-mail::button>',
                dotAll: true,
              ),
              pair,
            ),
            (t) => replaceAttributeTags(
              t,
              open: '<x-mail::button',
              boundary: true,
              attribute: 'url',
              close: '</x-mail::button>',
              replace: (a, b) => '{$a|$b}',
            ),
          ),
          (
            'replaceAttributeTags, links',
            (t) => t.replaceAllMapped(
              RegExp(r'<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>', dotAll: true),
              pair,
            ),
            (t) => replaceAttributeTags(
              t,
              open: '<a ',
              boundary: false,
              attribute: 'href',
              close: '</a>',
              replace: (a, b) => '{$a|$b}',
            ),
          ),
          (
            'removeTags',
            (t) => t.replaceAll(RegExp(r'<[^>]+>'), ''),
            removeTags,
          ),
          (
            'replaceLinks',
            (t) => t.replaceAllMapped(RegExp(r'\[([^\]]*)\]\(([^)]*)\)'), pair),
            (t) => replaceLinks(t, (a, b) => '{$a|$b}'),
          ),
          (
            'nameAndAddress',
            (t) {
              final m = RegExp(r'^\s*(.*?)\s*<([^<>]+)>\s*$').firstMatch(t);
              return m == null ? 'null' : pair(m);
            },
            (t) {
              final parts = nameAndAddress(t);
              return parts == null ? 'null' : '{${parts.$1}|${parts.$2}}';
            },
          ),
        ]) {
      test('$label: 100 000 random values', () {
        for (var i = 0; i < 100000; i++) {
          final text = value(i.isEven ? 6 : 14);
          expect(actual(text), expected(text), reason: text);
        }
      });
    }

    test('replaceAttributeTags: values written out', () {
      final regex = RegExp(
        r'<a [^>]*href="([^"]*)"[^>]*>(.*?)</a>',
        dotAll: true,
      );
      for (final text in [
        // The value holds `>`: the tag ends at the first `>` after it.
        '<a href="x>y">t</a>',
        // The largest candidate fails (no `"` after it), the second wins.
        '<a href="a" href="b>t</a>',
        // Two candidates before the first `>`, the last one is taken.
        '<a href="a" href="b">t</a>',
        // The largest candidate's tag has no closing tag after it, the
        // second candidate's tag ends earlier and has one.
        '<a href="a" x href="b>">t</a> </a',
        // No closing tag at all, then one after another opener.
        '<a href="a">t <a href="b">u</a>',
        '<a href="a"> <a ',
        '',
      ]) {
        expect(
          replaceAttributeTags(
            text,
            open: '<a ',
            boundary: false,
            attribute: 'href',
            close: '</a>',
            replace: (a, b) => '{$a|$b}',
          ),
          text.replaceAllMapped(regex, (m) => '{${m[1]}|${m[2]}}'),
          reason: text,
        );
      }
    });

    test('MailTheme.render, markdownToText and MailAddress.parse: what the '
        'regular expressions gave on 300 random values', () {
      const theme = MailTheme(appName: 'App');
      String outcome(Object? Function() run) {
        try {
          final result = run();
          return result is MailAddress
              ? '${result.name}|${result.email}'
              : '$result';
        } on Object catch (error) {
          return 'throws ${error.runtimeType}';
        }
      }

      for (final (input, html, text, address) in mailGolden) {
        expect(outcome(() => theme.render(input)), html, reason: input);
        expect(outcome(() => markdownToText(input)), text, reason: input);
        expect(outcome(() => MailAddress.parse(input)), address, reason: input);
      }
    });
  });

  // Three sizes, n, 8n and 64n: the step 8n to 64n is judged, about 8
  // linear and 64 quadratic; the limit of 32 sits between.
  group('linear in the length', () {
    double ms(void Function() run) {
      run();
      var best = double.infinity;
      for (var i = 0; i < 3; i++) {
        final watch = Stopwatch()..start();
        run();
        final time = watch.elapsedMicroseconds / 1000;
        if (time < best) {
          best = time;
        }
      }
      return best;
    }

    const theme = MailTheme(appName: 'App');
    for (final (label, run, base) in <(String, void Function(int), int)>[
      ('markdownToText, < without >', (n) => markdownToText('<' * n), 50000),
      ('markdownToText, [ without ]', (n) => markdownToText('[' * n), 50000),
      (
        'markdownToText, <a  without >',
        (n) => markdownToText('<a ' * (n ~/ 3)),
        50000,
      ),
      (
        'markdownToText, <a href=" without >',
        (n) => markdownToText('<a href="' * (n ~/ 9)),
        50000,
      ),
      (
        'markdownToText, [x]( without )',
        (n) => markdownToText('[x](' * (n ~/ 4)),
        50000,
      ),
      (
        'markdownToText, buttons without a closing tag',
        (n) => markdownToText('<x-mail::button url="u">' * (n ~/ 24)),
        50000,
      ),
      (
        'MailTheme.render, panels without a closing tag',
        (n) => theme.render('<x-mail::panel>' * (n ~/ 15)),
        8000,
      ),
      (
        'MailAddress.parse, a run of spaces',
        (n) {
          try {
            MailAddress.parse('a${' ' * n}b');
          } on ArgumentError {
            // Not an address; the time is what counts.
          }
        },
        50000,
      ),
    ]) {
      test(label, () {
        final small = ms(() => run(base));
        final middle = ms(() => run(base * 8));
        final large = ms(() => run(base * 64));
        final shown =
            '$base: ${small.toStringAsFixed(2)} ms, ${base * 8}: '
            '${middle.toStringAsFixed(2)} ms, ${base * 64}: '
            '${large.toStringAsFixed(2)} ms';
        expect(large / middle, lessThan(32), reason: shown);
        expect(large, lessThan(10000), reason: shown);
      });
    }
  });
}
