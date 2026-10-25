import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('calendar math (Carbon 3)', () {
    test('months and years overflow like Carbon, NoOverflow clamps', () {
      expect(DateTime(2026, 1, 31).addMonths(1), DateTime(2026, 3, 3));
      expect(
        DateTime(2026, 1, 31).addMonthsNoOverflow(1),
        DateTime(2026, 2, 28),
      );
      expect(DateTime(2026, 3, 31).subMonths(1), DateTime(2026, 3, 3));
      expect(
        DateTime(2026, 3, 31).subMonthsNoOverflow(1),
        DateTime(2026, 2, 28),
      );
      expect(DateTime(2024, 2, 29).addYears(1), DateTime(2025, 3, 1));
      expect(
        DateTime(2024, 2, 29).addYearsNoOverflow(1),
        DateTime(2025, 2, 28),
      );
      expect(
        DateTime.utc(2026, 1, 15, 9, 30).addMonths(13),
        DateTime.utc(2027, 2, 15, 9, 30),
      );
    });

    test('start and end of week, month, year', () {
      final sunday = DateTime.utc(2026, 10, 25, 15, 30);
      expect(sunday.startOfWeek, DateTime.utc(2026, 10, 19));
      expect(
        sunday.endOfWeek,
        DateTime.utc(2026, 10, 25, 23, 59, 59, 999, 999),
      );
      expect(
        DateTime.utc(2026, 10, 19, 8).startOfWeek,
        DateTime.utc(2026, 10, 19),
      );
      expect(sunday.startOfMonth, DateTime.utc(2026, 10));
      expect(
        sunday.endOfMonth,
        DateTime.utc(2026, 10, 31, 23, 59, 59, 999, 999),
      );
      expect(
        sunday.endOfYear,
        DateTime.utc(2026, 12, 31, 23, 59, 59, 999, 999),
      );
      expect(sunday.daysInMonth, 31);
      expect(DateTime(2028, 2, 3).daysInMonth, 29);
      expect(sunday.isWeekend, isTrue);
      expect(DateTime(2026, 10, 26).isWeekday, isTrue);
      final start = DateTime.utc(2026, 10, 25, 15, 30);
      final end = DateTime.utc(2026, 10, 26);
      expect(sunday.isBetween(start, end), isTrue);
      expect(sunday.isBetween(start, end, inclusive: false), isFalse);
      expect(sunday.isSameDay(DateTime.utc(2026, 10, 25, 1)), isTrue);
      expect(sunday.isSameMonth(DateTime.utc(2026, 10, 1)), isTrue);
    });
  });
}
