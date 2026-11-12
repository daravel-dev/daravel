import 'package:daravel_horizon/src/reservation.dart';
import 'package:test/test.dart';

/// The master's reading of a worker's reservation report.
void main() {
  // A second boundary, as epoch milliseconds.
  const second = 1800000000 * 1000;
  const threeSeconds = Duration(seconds: 3);

  group('the same retry_after on both sides: the driver\'s value, exactly', () {
    // The database queue's reservation of a pop at .f s (whole seconds):
    // second + 3 s, wherever in the second the pop fell. The worker saw it
    // a few milliseconds after the pop.
    for (final fraction in [0, 500, 999]) {
      test('popped at .$fraction s', () {
        final result = reservationExpiry(
          retryAfter: threeSeconds,
          reservedAtMs: second + fraction + 5,
          reservedUntilMs: second + 3000,
          reportedRetryAfterMs: 3000,
        );
        // Not cut by the second an estimate would take off.
        expect(result.expiry!.millisecondsSinceEpoch, second + 3000);
        expect(result.mismatch, isFalse);
      });
    }
  });

  test('another retry_after on the worker: the earlier of its value and the '
      'master\'s estimate, flagged', () {
    final result = reservationExpiry(
      retryAfter: threeSeconds,
      reservedAtMs: second + 500,
      reservedUntilMs: second + 90000,
      reportedRetryAfterMs: 90000,
    );
    // reservedAt + 3 s - 1 s.
    expect(result.expiry!.millisecondsSinceEpoch, second + 2500);
    expect(result.mismatch, isTrue);

    final shorter = reservationExpiry(
      retryAfter: const Duration(seconds: 90),
      reservedAtMs: second + 500,
      reservedUntilMs: second + 3000,
      reportedRetryAfterMs: 3000,
    );
    expect(shorter.expiry!.millisecondsSinceEpoch, second + 3000);
    expect(shorter.mismatch, isTrue);
  });

  test('a worker that reports no reservedUntil (a driver that does not say, '
      'an older worker): the estimate, not flagged', () {
    final result = reservationExpiry(
      retryAfter: threeSeconds,
      reservedAtMs: second + 500,
    );
    expect(result.expiry!.millisecondsSinceEpoch, second + 2500);
    expect(result.mismatch, isFalse);
  });

  test('a reservedUntil without the worker\'s retry_after: the earlier, not '
      'flagged', () {
    final result = reservationExpiry(
      retryAfter: threeSeconds,
      reservedAtMs: second + 500,
      reservedUntilMs: second + 3000,
    );
    expect(result.expiry!.millisecondsSinceEpoch, second + 2500);
    expect(result.mismatch, isFalse);
  });

  test('nothing reported: null', () {
    expect(reservationExpiry(retryAfter: threeSeconds).expiry, isNull);
  });
}
