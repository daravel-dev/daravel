import '../foundation/clock.dart';

/// `10.minutes`, `7.days` for `Cache.remember`, token expiry, `travel()`.
extension DaravelDurationInt on int {
  Duration get milliseconds => Duration(milliseconds: this);
  Duration get seconds => Duration(seconds: this);
  Duration get minutes => Duration(minutes: this);
  Duration get hours => Duration(hours: this);
  Duration get days => Duration(days: this);
  Duration get weeks => Duration(days: this * 7);
}

/// `15.minutes.fromNow`, `7.days.ago`, on the testable [Clock].
extension DaravelDuration on Duration {
  DateTime get fromNow => Clock.now().add(this);
  DateTime get ago => Clock.now().subtract(this);
}

/// Carbon-style helpers, relative to [Clock.now] (so `freezeTime()` and
/// `travel()` apply).
extension DaravelDateTime on DateTime {
  bool get isPast => isBefore(Clock.now());
  bool get isFuture => isAfter(Clock.now());

  bool get isToday {
    final now = isUtc ? Clock.now().toUtc() : Clock.now().toLocal();
    return year == now.year && month == now.month && day == now.day;
  }

  DateTime get startOfDay =>
      isUtc ? DateTime.utc(year, month, day) : DateTime(year, month, day);

  DateTime get endOfDay => _at(year, month, day, 23, 59, 59, 999, 999);

  DateTime _at(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
    int second = 0,
    int millisecond = 0,
    int microsecond = 0,
  ]) => isUtc
      ? DateTime.utc(
          year,
          month,
          day,
          hour,
          minute,
          second,
          millisecond,
          microsecond,
        )
      : DateTime(
          year,
          month,
          day,
          hour,
          minute,
          second,
          millisecond,
          microsecond,
        );

  DateTime _withDate(int year, int month, int day) =>
      _at(year, month, day, hour, minute, second, millisecond, microsecond);

  // Calendar math, as Carbon: `addMonths` overflows into the next month
  // (Jan 31 + 1 month = Mar 3), `addMonthsNoOverflow` stays in the target
  // month (Feb 28).

  DateTime addMonths(int months) => _withDate(year, month + months, day);
  DateTime subMonths(int months) => addMonths(-months);
  DateTime addYears(int years) => _withDate(year + years, month, day);
  DateTime subYears(int years) => addYears(-years);

  DateTime addMonthsNoOverflow(int months) {
    final first = DateTime.utc(year, month + months);
    final last = DateTime.utc(first.year, first.month + 1, 0).day;
    return _withDate(first.year, first.month, day > last ? last : day);
  }

  DateTime subMonthsNoOverflow(int months) => addMonthsNoOverflow(-months);
  DateTime addYearsNoOverflow(int years) => addMonthsNoOverflow(years * 12);
  DateTime subYearsNoOverflow(int years) => addMonthsNoOverflow(-years * 12);

  int get daysInMonth => DateTime.utc(year, month + 1, 0).day;

  DateTime get startOfMonth => _at(year, month, 1);
  DateTime get endOfMonth =>
      _at(year, month, daysInMonth, 23, 59, 59, 999, 999);
  DateTime get startOfYear => _at(year, 1, 1);
  DateTime get endOfYear => _at(year, 12, 31, 23, 59, 59, 999, 999);

  /// Monday 00:00 of this week (Carbon's default for `en` and `id`).
  DateTime get startOfWeek => _at(year, month, day - (weekday - 1));

  /// Sunday 23:59:59.999999 of this week.
  DateTime get endOfWeek =>
      _at(year, month, day + (7 - weekday), 23, 59, 59, 999, 999);

  bool get isWeekend =>
      weekday == DateTime.saturday || weekday == DateTime.sunday;
  bool get isWeekday => !isWeekend;

  bool isSameDay(DateTime other) =>
      year == other.year && month == other.month && day == other.day;
  bool isSameMonth(DateTime other) =>
      year == other.year && month == other.month;
  bool isSameYear(DateTime other) => year == other.year;

  /// Carbon's `between()`: [start] and [end] included unless
  /// [inclusive] is false.
  bool isBetween(DateTime start, DateTime end, {bool inclusive = true}) =>
      inclusive
      ? !isBefore(start) && !isAfter(end)
      : isAfter(start) && isBefore(end);

  /// Carbon's `diffForHumans()`: the largest whole calendar unit, so
  /// `5 minutes ago`, `2 hours from now`, `4 weeks ago`, `1 month ago`
  /// (`en`), or `5 menit yang lalu`, `2 jam dari sekarang` (`id`). With
  /// [other], relative to it: `1 day before` / `1 hari sebelumnya`.
  String diffForHumans({DateTime? other, String locale = 'en'}) {
    final reference = other ?? Clock.now();
    final base = isUtc ? reference.toUtc() : reference.toLocal();
    final past = !isAfter(base);
    final (count, unit) = _largestUnit(past ? this : base, past ? base : this);
    final indonesian = locale.toLowerCase().startsWith('id');
    final time = indonesian
        ? '$count ${_idUnits[unit]}'
        : '$count $unit${count == 1 ? '' : 's'}';
    if (indonesian) {
      return other == null
          ? (past ? '$time yang lalu' : '$time dari sekarang')
          : (past ? '$time sebelumnya' : '$time setelahnya');
    }
    return other == null
        ? (past ? '$time ago' : '$time from now')
        : (past ? '$time before' : '$time after');
  }

  static const Map<String, String> _idUnits = {
    'year': 'tahun',
    'month': 'bulan',
    'week': 'minggu',
    'day': 'hari',
    'hour': 'jam',
    'minute': 'menit',
    'second': 'detik',
  };

  /// Calendar difference as PHP's `DateTime::diff` computes it (borrowing
  /// from the month before [later]'s), then its largest non-zero unit.
  static (int, String) _largestUnit(DateTime earlier, DateTime later) {
    var seconds = later.second - earlier.second;
    var minutes = later.minute - earlier.minute;
    var hours = later.hour - earlier.hour;
    var days = later.day - earlier.day;
    var months = later.month - earlier.month;
    var years = later.year - earlier.year;
    if (seconds < 0) {
      seconds += 60;
      minutes--;
    }
    if (minutes < 0) {
      minutes += 60;
      hours--;
    }
    if (hours < 0) {
      hours += 24;
      days--;
    }
    if (days < 0) {
      // Days in the month before `later`'s month.
      days += DateTime.utc(later.year, later.month, 0).day;
      months--;
    }
    if (months < 0) {
      months += 12;
      years--;
    }
    return switch ((years, months, days, hours, minutes)) {
      (> 0, _, _, _, _) => (years, 'year'),
      (_, > 0, _, _, _) => (months, 'month'),
      (_, _, >= 7, _, _) => (days ~/ 7, 'week'),
      (_, _, > 0, _, _) => (days, 'day'),
      (_, _, _, > 0, _) => (hours, 'hour'),
      (_, _, _, _, > 0) => (minutes, 'minute'),
      _ => (seconds, 'second'),
    };
  }
}
