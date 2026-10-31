import 'dart:math' as math;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Decorrelated jitter: each wait is random, grows with the one before, and
/// is capped, so colliding isolates spread out instead of retrying as one.
void main() {
  const base = DatabaseManager.retryBaseDelay;
  const max = DatabaseManager.retryMaxDelay;

  test('a wait stays between the base and three times the last one', () {
    final random = math.Random(1);
    var previous = base;
    for (var i = 0; i < 500; i++) {
      final next = DatabaseManager.retryDelay(previous, random);
      expect(next, greaterThanOrEqualTo(base));
      expect(next, lessThanOrEqualTo(previous * 3));
      expect(next, lessThanOrEqualTo(max));
      previous = next;
    }
  });

  test('it never passes the cap', () {
    final random = math.Random(2);
    for (var i = 0; i < 200; i++) {
      expect(
        DatabaseManager.retryDelay(const Duration(seconds: 5), random),
        lessThanOrEqualTo(max),
      );
    }
  });

  test('two isolates in the same state wait differently', () {
    final first = math.Random(3);
    final second = math.Random(4);
    final waits = [
      for (var i = 0; i < 20; i++)
        (
          DatabaseManager.retryDelay(max, first),
          DatabaseManager.retryDelay(max, second),
        ),
    ];
    expect(waits.where((w) => w.$1 != w.$2), isNotEmpty);
  });
}
