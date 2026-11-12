import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/email_rfc.dart';
import 'package:test/test.dart';

/// The egulias port reads an address in time linear in its length. Appending
/// to a String token by token (the recorded parts, the domain, its labels,
/// the literal) copied the whole text each time: 100 000 characters took 1
/// to 4.5 s, and a 1 MiB body minutes. The lexer splits by hand what a
/// regex split before, and the split must stay the same.
void main() {
  test('the lexer splits as doctrine\'s regex does', () {
    final reference = RegExp(
      emailRfcScanPattern,
      caseSensitive: false,
      unicode: true,
    );
    List<String> byRegex(String input) {
      final out = <String>[];
      var last = 0;
      for (final m in reference.allMatches(input)) {
        if (m.start > last) {
          out.add(input.substring(last, m.start));
        }
        for (var g = 1; g <= 7; g++) {
          final captured = m.group(g);
          if (captured != null && captured.isNotEmpty) {
            out.add(captured);
            break;
          }
        }
        last = m.end;
      }
      if (last < input.length) {
        out.add(input.substring(last));
      }
      return out;
    }

    final random = Random(20261112);
    final pieces = [
      'a', 'Z', 'IPv', '4', '6', '9', '0', ':', '::', ':::', '.', '@', '"',
      r'\', '(', ')', '[', ']', ' ', '\t', '\r', '\n', '\r\n', '\x0b',
      '\x0c', '\x00', '\x7f', '-', '_', '#', '!',
      String.fromCharCode(0xE9), // é
      String.fromCharCode(0x017F), // ſ, folds to s
      String.fromCharCode(0x212A), // Kelvin sign, folds to k
      String.fromCharCode(0x2028), // line separator
      String.fromCharCode(0x00A0), // no-break space
      String.fromCharCode(0x4E2D),
      String.fromCharCode(0xD83D) + String.fromCharCode(0xDE00), // emoji
      String.fromCharCode(0xD800), // a lone surrogate
    ];
    for (var i = 0; i < 20000; i++) {
      final input = [
        for (var j = random.nextInt(12); j >= 0; j--)
          pieces[random.nextInt(pieces.length)],
      ].join();
      expect(
        emailRfcTokens(input),
        byRegex(input),
        reason: input.runes.toList().toString(),
      );
    }
  });

  // Growth, not a wall-clock bound: the time for 100 000 characters over
  // the time for 25 000, each the fastest of three runs. Linear gives about
  // 4, quadratic about 16; a loaded machine slows both sizes alike.
  group('linear in the length of the address', () {
    final q = String.fromCharCode(0x22);
    final bs = String.fromCharCode(0x5C);
    final shapes = <String, String Function(int)>{
      'dot-separated atoms': (n) => '${'a.' * (n ~/ 2)}a@example.com',
      'quoted words': (n) => '$q${'a ' * (n ~/ 2)}$q@example.com',
      'quoted escaped quotes': (n) => '$q${'$bs$q' * (n ~/ 2)}$q@example.com',
      'open comments': (n) => '${'(' * n}a@example.com',
      'comment pairs': (n) => '${'()' * (n ~/ 2)}a@example.com',
      'domain labels': (n) => 'a@${'b.' * (n ~/ 2)}com',
      'IPv6 literal': (n) => 'a@[IPv6:${'1:' * (n ~/ 2)}1]',
      'unclosed bracket': (n) => 'a@[${'1.' * (n ~/ 2)}',
      'non-ASCII letters': (n) => '${String.fromCharCode(0xE9) * n}@x.com',
      // Punycode's time grows with the square of the distinct code points:
      // a domain label of n different letters (surrogates skipped).
      'distinct non-ASCII label': (n) =>
          'a@${String.fromCharCodes([for (var i = 0; i < n; i++) 0x4E00 + i + (0x4E00 + i >= 0xD800 ? 0x800 : 0)])}.com',
    };
    Future<int> fastest(String value, String rule) async {
      var best = 1 << 62;
      for (var i = 0; i < 3; i++) {
        final watch = Stopwatch()..start();
        await Validator({'v': value}, {'v': rule}).run();
        best = min(best, watch.elapsedMicroseconds);
      }
      return best;
    }

    for (final MapEntry(key: name, value: shape) in shapes.entries) {
      for (final rule in ['email:rfc', 'email:strict']) {
        test('$name, $rule', () async {
          await fastest(shape(1000), rule);
          final small = await fastest(shape(25000), rule);
          final large = await fastest(shape(100000), rule);
          expect(
            large / max(small, 1),
            lessThan(10),
            reason: '25 000: $small µs, 100 000: $large µs',
          );
        });
      }
    }
  });
}
