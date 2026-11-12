@Tags(['security'])
library;

import 'dart:math';

import 'package:daravel/src/broadcasting/channel_registry.dart';
import 'package:test/test.dart';

/// What `ChannelRegistry.channel` compiled a pattern to before: Laravel's
/// `/^…$/` with `([^.]+)` for each placeholder.
List<String>? oldMatch(String pattern, String name) {
  final source = pattern.splitMapJoin(
    RegExp(r'\{(.*?)\}'),
    onMatch: (_) => '([^.]+)',
    onNonMatch: RegExp.escape,
  );
  final match = RegExp('^$source\$').firstMatch(name);
  return match == null
      ? null
      : [for (var i = 1; i <= match.groupCount; i++) match[i]!];
}

/// Channel patterns are matched in time linear in the channel name: the
/// regular expression they replace backtracked polynomially on a name it
/// did not match, for placeholders not separated by `.` or side by side.
void main() {
  test('the same matches and values as the regular expression, on 20 000 '
      'random patterns and names', () {
    final random = Random(20261112);
    String pick(String alphabet, int max) => String.fromCharCodes([
      for (var i = random.nextInt(max + 1); i > 0; i--)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
    var matched = 0;
    for (var i = 0; i < 20000; i++) {
      // Literals and placeholders in any order: side by side, separated
      // by a dot, a dash or nothing, or no placeholder at all.
      final pattern = StringBuffer();
      for (var t = random.nextInt(5); t >= 0; t--) {
        if (random.nextBool()) {
          pattern.write('{${pick('xy', 2)}}');
        } else {
          pattern.write(pick('ab.-', 3));
        }
      }
      final name = pick('ab.-', 12);
      final expected = oldMatch('$pattern', name);
      expect(
        ChannelPattern('$pattern').match(name),
        expected,
        reason: 'pattern "$pattern", name "$name"',
      );
      if (expected != null) {
        matched++;
      }
    }
    expect(matched, greaterThan(1000), reason: 'enough matches compared');
  });

  test('known patterns', () {
    expect(ChannelPattern('orders.{id}').match('orders.7'), ['7']);
    expect(ChannelPattern('orders.{id}').match('orders.7.x'), isNull);
    expect(ChannelPattern('App.Models.User.{id}').match('App.Models.User.12'), [
      '12',
    ]);
    expect(ChannelPattern('chat.{room}.{thread}').match('chat.r.t'), [
      'r',
      't',
    ]);
    expect(ChannelPattern('{a}{b}').match('abc'), ['ab', 'c']);
    expect(ChannelPattern('dash-{a}-{b}').match('dash-x-y-z'), ['x-y', 'z']);
    expect(ChannelPattern('news').match('news'), <String>[]);
    expect(ChannelPattern('news').match('newsx'), isNull);
    expect(ChannelPattern('orders.{id}').names, ['id']);
  });

  // Time for n and 2n characters on a name that does not match: about
  // twice as long when linear; the regular expression took 4 times as
  // long (two placeholders) and 8 to 10 times (three).
  group('linear in the name', () {
    double ms(ChannelPattern pattern, String name) {
      pattern.match(name);
      final times = <double>[];
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        pattern.match(name);
        times.add(watch.elapsedMicroseconds / 1000);
      }
      times.sort();
      return times[2];
    }

    for (final (label, pattern, name) in [
      ('pair.{a}{b}', 'pair.{a}{b}', (int n) => 'pair.${'a' * n}.'),
      ('dash-{a}-{b}', 'dash-{a}-{b}', (int n) => 'dash-${'-' * n}.'),
      ('triple.{a}{b}{c}', 'triple.{a}{b}{c}', (int n) => 'triple.${'a' * n}.'),
    ]) {
      test(label, () {
        final compiled = ChannelPattern(pattern);
        expect(compiled.match(name(10)), isNull);
        final small = ms(compiled, name(100000));
        final large = ms(compiled, name(200000));
        expect(
          large / small,
          lessThan(3.5),
          reason:
              '100 000 chars: ${small.toStringAsFixed(1)} ms, '
              '200 000: ${large.toStringAsFixed(1)} ms',
        );
        expect(large, lessThan(500), reason: '200 000 characters');
      });
    }
  });
}
