import '../foundation/exceptions.dart';

/// Raised for malformed cron expressions.
final class CronFormatException extends DaravelException {
  const CronFormatException(super.message);
}

/// A five-field cron expression (`minute hour day-of-month month
/// day-of-week`) with ranges, steps, lists, names and `@aliases`.
final class CronExpression {
  CronExpression._(
    this.expression,
    this._minutes,
    this._hours,
    this._days,
    this._months,
    this._weekdays,
  );

  /// Parses [expression]; throws [CronFormatException] when invalid.
  factory CronExpression.parse(String expression) {
    final normalized =
        _aliases[expression.trim().toLowerCase()] ?? expression.trim();
    final fields = normalized.split(RegExp(r'\s+'));
    if (fields.length != 5) {
      throw CronFormatException(
        'Cron expression [$expression] must have 5 fields; got ${fields.length}.',
      );
    }
    return CronExpression._(
      normalized,
      _field(fields[0], 0, 59, const {}),
      _field(fields[1], 0, 23, const {}),
      _field(fields[2], 1, 31, const {}),
      _field(fields[3], 1, 12, _monthNames),
      _field(fields[4], 0, 7, _dayNames).map((d) => d == 7 ? 0 : d).toSet(),
    );
  }

  static const Map<String, String> _aliases = {
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
    '@monthly': '0 0 1 * *',
    '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *',
    '@midnight': '0 0 * * *',
    '@hourly': '0 * * * *',
  };

  static const Map<String, int> _monthNames = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static const Map<String, int> _dayNames = {
    'sun': 0,
    'mon': 1,
    'tue': 2,
    'wed': 3,
    'thu': 4,
    'fri': 5,
    'sat': 6,
  };

  final String expression;
  final Set<int> _minutes;
  final Set<int> _hours;
  final Set<int> _days;
  final Set<int> _months;
  final Set<int> _weekdays;

  /// Whether [time] (truncated to the minute) matches.
  bool matches(DateTime time) =>
      _minutes.contains(time.minute) &&
      _hours.contains(time.hour) &&
      _months.contains(time.month) &&
      _days.contains(time.day) &&
      _weekdays.contains(time.weekday % 7);

  /// The next matching minute strictly after [after] (within four years).
  DateTime? next(DateTime after) {
    var candidate = DateTime.utc(
      after.year,
      after.month,
      after.day,
      after.hour,
      after.minute,
    ).add(const Duration(minutes: 1));
    final limit = candidate.add(const Duration(days: 366 * 4));
    while (candidate.isBefore(limit)) {
      if (!_months.contains(candidate.month)) {
        candidate = DateTime.utc(candidate.year, candidate.month + 1);
        continue;
      }
      if (!_days.contains(candidate.day) ||
          !_weekdays.contains(candidate.weekday % 7)) {
        candidate = DateTime.utc(
          candidate.year,
          candidate.month,
          candidate.day + 1,
        );
        continue;
      }
      if (!_hours.contains(candidate.hour)) {
        candidate = DateTime.utc(
          candidate.year,
          candidate.month,
          candidate.day,
          candidate.hour + 1,
        );
        continue;
      }
      if (!_minutes.contains(candidate.minute)) {
        candidate = candidate.add(const Duration(minutes: 1));
        continue;
      }
      return candidate;
    }
    return null;
  }

  static Set<int> _field(String raw, int min, int max, Map<String, int> names) {
    final result = <int>{};
    for (final part in raw.toLowerCase().split(',')) {
      final stepSplit = part.split('/');
      if (stepSplit.length > 2) {
        throw CronFormatException('Invalid cron field [$raw].');
      }
      final step = stepSplit.length == 2 ? int.tryParse(stepSplit[1]) : 1;
      if (step == null || step < 1) {
        throw CronFormatException('Invalid step in cron field [$raw].');
      }
      final range = stepSplit[0];
      int start;
      int end;
      if (range == '*' || range == '?') {
        start = min;
        end = max;
      } else if (range.contains('-')) {
        final bounds = range.split('-');
        if (bounds.length != 2) {
          throw CronFormatException('Invalid range in cron field [$raw].');
        }
        start = _value(bounds[0], names, raw);
        end = _value(bounds[1], names, raw);
      } else {
        start = _value(range, names, raw);
        end = stepSplit.length == 2 ? max : start;
      }
      if (start < min || end > max || start > end) {
        throw CronFormatException(
          'Cron field [$raw] is out of range $min-$max.',
        );
      }
      for (var v = start; v <= end; v += step) {
        result.add(v);
      }
    }
    return result;
  }

  static int _value(String token, Map<String, int> names, String raw) {
    final named = names[token];
    if (named != null) {
      return named;
    }
    final parsed = int.tryParse(token);
    if (parsed == null) {
      throw CronFormatException('Invalid value [$token] in cron field [$raw].');
    }
    return parsed;
  }

  @override
  String toString() => expression;
}
