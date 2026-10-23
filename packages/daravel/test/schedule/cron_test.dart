import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  test('parses ranges, steps, lists, names and aliases', () {
    final every5 = CronExpression.parse('*/5 * * * *');
    expect(every5.matches(DateTime.utc(2026, 10, 24, 12, 0)), isTrue);
    expect(every5.matches(DateTime.utc(2026, 10, 24, 12, 5)), isTrue);
    expect(every5.matches(DateTime.utc(2026, 10, 24, 12, 7)), isFalse);

    final office = CronExpression.parse('30 9-17/4 * JAN,jun mon-fri');
    expect(office.matches(DateTime.utc(2026, 1, 5, 9, 30)), isTrue); // Monday
    expect(office.matches(DateTime.utc(2026, 1, 5, 13, 30)), isTrue);
    expect(office.matches(DateTime.utc(2026, 1, 5, 10, 30)), isFalse);
    expect(office.matches(DateTime.utc(2026, 1, 4, 9, 30)), isFalse); // Sunday
    expect(office.matches(DateTime.utc(2026, 2, 2, 9, 30)), isFalse); // Feb

    expect(CronExpression.parse('@hourly').expression, '0 * * * *');
    expect(
      CronExpression.parse('@daily').matches(DateTime.utc(2026, 1, 1)),
      isTrue,
    );
    // Sunday as 7 is normalised to 0.
    expect(
      CronExpression.parse('0 0 * * 7').matches(DateTime.utc(2026, 1, 4)),
      isTrue,
    );
  });

  test('rejects malformed expressions', () {
    for (final bad in [
      '* * * *',
      '60 * * * *',
      '* 24 * * *',
      'a * * * *',
      '*/0 * * * *',
      '5-1 * * * *',
    ]) {
      expect(
        () => CronExpression.parse(bad),
        throwsA(isA<CronFormatException>()),
        reason: bad,
      );
    }
  });

  test('next() finds the following match across day/month boundaries', () {
    final nightly = CronExpression.parse('0 3 * * *');
    expect(
      nightly.next(DateTime.utc(2026, 10, 24, 3, 0)),
      DateTime.utc(2026, 10, 25, 3),
    );
    expect(
      nightly.next(DateTime.utc(2026, 10, 24, 2, 59)),
      DateTime.utc(2026, 10, 24, 3),
    );
    final monthly = CronExpression.parse('0 0 1 * *');
    expect(monthly.next(DateTime.utc(2026, 10, 24)), DateTime.utc(2026, 11, 1));
    final feb29 = CronExpression.parse('0 0 29 2 *');
    expect(feb29.next(DateTime.utc(2026, 1, 1)), DateTime.utc(2028, 2, 29));
    final weekday = CronExpression.parse('0 9 * * 1-5');
    expect(
      weekday.next(DateTime.utc(2026, 10, 24, 10)),
      DateTime.utc(2026, 10, 26, 9),
    ); // Sat → Mon
  });
}
