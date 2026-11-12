import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/key_pattern.dart';
import 'package:test/test.dart';

/// [KeyPattern] decides as the regular expressions it replaces
/// (`[^.]+` per `*` for `distinct`, `.*` with `dotAll` for `in_array`), in
/// time linear in the key: those regexes backtracked quadratically on a
/// key with two `*` and a literal tail, cubically with three.
void main() {
  RegExp reference(String pattern, {required bool crossDots}) => RegExp(
    '^${pattern.split('*').map(RegExp.escape).join(crossDots ? '.*' : '[^.]+')}\$',
    dotAll: true,
    unicode: true,
  );

  test('the same as the regex on random keys and patterns', () {
    final random = Random(20261112);
    const keyParts = ['a', 'b', '.', '..', 'ab', '\n', '*', 'é', '\u{1F600}'];
    const patternParts = ['a', 'b', '.', '*', '**', '*.', '.*', 'ab', '\n'];
    String build(List<String> parts, int max) => [
      for (var i = random.nextInt(max + 1); i > 0; i--)
        parts[random.nextInt(parts.length)],
    ].join();
    var matched = 0;
    for (var i = 0; i < 50000; i++) {
      final pattern = build(patternParts, 6);
      final key = build(keyParts, 8);
      for (final crossDots in [false, true]) {
        final expected = reference(pattern, crossDots: crossDots).hasMatch(key);
        expect(
          KeyPattern(pattern, crossDots: crossDots).matches(key),
          expected,
          reason:
              'pattern ${pattern.codeUnits} key ${key.codeUnits} '
              'crossDots $crossDots',
        );
        if (expected) {
          matched++;
        }
      }
    }
    expect(matched, greaterThan(2000));
  });

  // Growth through the validator, not a wall-clock bound: one input key of
  // 4n characters over n, each the fastest of three. Linear is about 4;
  // the regex was about 16 with two `*` and 64 with three.
  Future<int> fastest(Map<String, Object?> data, String rule) async {
    var best = 1 << 62;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await Validator(data, {'items.*': rule}).run();
      best = min(best, watch.elapsedMicroseconds);
    }
    return best;
  }

  for (final (name, rule, key) in [
    ('two stars', 'in_array:a.*.b.*.c', (int n) => 'a${'.b' * n}x'),
    ('three stars', 'in_array:a.*.b.*.b.*.c', (int n) => 'a${'.b' * n}x'),
    (
      'a literal tail that does not match',
      'in_array:a.*.b.*.c',
      (int n) => 'a${'.b' * n}.c.d',
    ),
    (
      'distinct, one key per star',
      'distinct',
      (int n) => 'items.${'b' * (2 * n)}',
    ),
  ]) {
    test('linear in the length of a key: $name', () async {
      Map<String, Object?> data(int n) => {
        'items': [1],
        key(n): 1,
      };
      await fastest(data(100), rule);
      final small = await fastest(data(4000), rule);
      final large = await fastest(data(16000), rule);
      expect(
        large < 5000 || large / max(small, 1) < 10,
        isTrue,
        reason: '4 000: $small µs, 16 000: $large µs',
      );
    });
  }
}
